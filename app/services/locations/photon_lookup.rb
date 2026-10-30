require "geocoder"
require "geocoder/lookups/photon"

module Locations
  # Preserve strict response validation around Geocoder's Photon adapter.
  class PhotonLookup < Geocoder::Lookup::Photon
    module HttpTransport
      def self.start(host, port, **options, &block)
        Net::HTTP.start(
          host, port,
          **options.merge(open_timeout: 2, read_timeout: 3, write_timeout: 3, max_retries: 0),
          &block
        )
      end
    end

    def initialize(endpoint:, headers:)
      super()
      @endpoint = URI(endpoint)
      @endpoint.query = nil
      @endpoint.fragment = nil
      @configuration = Geocoder.config_for_lookup(:photon)
      @configuration.merge!(timeout: 3, always_raise: :all, http_headers: headers, cache: nil)
    end

    private

    def configuration
      @configuration
    end

    def http_client
      HttpTransport
    end

    def supported_protocols
      [ @endpoint.scheme.to_sym ]
    end

    def base_query_url(_query)
      "#{@endpoint}?"
    end

    def result_class
      Geocoder::Result::Photon
    end

    def check_response_for_errors!(response)
      return if response.code.to_i == 200

      if response.code.to_i == 429
        raise Geocoder::OverQueryLimitError, "Location provider rate limit exceeded"
      end

      raise Geocoder::ServiceUnavailable, "Location provider returned HTTP #{response.code}"
    end

    def parse_raw_data(raw_data)
      payload = super
      unless payload.is_a?(Hash) && payload["type"] == "FeatureCollection" && payload["features"].is_a?(Array)
        raise Geocoder::ResponseParseError.new(raw_data)
      end

      payload
    end
  end
end
