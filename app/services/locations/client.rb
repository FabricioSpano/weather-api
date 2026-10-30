require "geocoder"

module Locations
  class Client
    class Error < StandardError; end
    class InvalidAddressError < Error; end
    class NotFoundError < Error; end
    class AmbiguousAddressError < Error; end
    class InvalidResponseError < Error; end
    class TimeoutError < Error; end
    class RateLimitError < Error; end
    class UnavailableError < Error; end

    Location = Data.define(:postal_code, :country, :country_code, :latitude, :longitude)

    DEFAULT_ENDPOINT = "https://photon.komoot.io/api/".freeze
    USER_AGENT = "WeatherApi/1.0 (https://github.com/FabricioSpano/weather-api)".freeze

    def initialize(endpoint: ENV.fetch("LOCATIONS_URL", DEFAULT_ENDPOINT))
      uri = URI(endpoint)
      unless %w[http https].include?(uri.scheme) && uri.host
        raise ArgumentError, "LOCATIONS_URL must be an HTTP or HTTPS URL"
      end

      @lookup = PhotonLookup.new(endpoint:, headers: { "Accept" => "application/json", "User-Agent" => USER_AGENT })
    end

    def call(address:)
      unless address.is_a?(String) && !address.strip.empty? && address.length <= 500
        raise InvalidAddressError, "Provide an address with at most 500 characters"
      end

      query = Geocoder::Query.new(address.strip, lookup: :photon, street_address: true, limit: 2, language: "en")
      if query.reverse_geocode?
        raise InvalidAddressError, "Provide a street address instead of coordinates"
      end

      results = @lookup.search(query)
      raise NotFoundError, "No location found for this address" if results.empty?
      if results.length > 1
        raise AmbiguousAddressError, "Address is ambiguous; include street number, city, region and country"
      end

      normalize(results.fetch(0))
    rescue Geocoder::ResponseParseError
      raise InvalidResponseError, "Location provider returned an invalid response"
    rescue Geocoder::OverQueryLimitError
      raise RateLimitError, "Location provider rate limit exceeded"
    rescue Timeout::Error
      raise TimeoutError, "Location provider timed out"
    rescue Geocoder::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      raise UnavailableError, "Location provider is unavailable"
    end

    private

    def normalize(result)
      feature = result.data
      unless feature.is_a?(Hash) && feature["type"] == "Feature" && feature["properties"].is_a?(Hash)
        raise InvalidResponseError, "Location provider returned an invalid feature"
      end

      properties = feature["properties"]
      postal_code = text(result.postal_code)
      country = text(result.country)
      # Geocoder 1.8's Photon result does not expose the provider's countrycode.
      country_code = text(properties["countrycode"]).upcase
      unless country_code.match?(/\A[A-Z]{2}\z/)
        raise InvalidResponseError, "Location provider returned an invalid country code"
      end

      latitude, longitude = coordinates(result)
      Location.new(postal_code:, country:, country_code:, latitude:, longitude:)
    end

    def text(value)
      unless value.is_a?(String) && !value.strip.empty?
        raise InvalidResponseError, "Location provider omitted a required address field"
      end

      value.strip
    end

    def coordinates(result)
      geometry = result.data["geometry"]
      unless geometry.is_a?(Hash) && geometry["type"] == "Point" &&
             geometry["coordinates"].is_a?(Array) && geometry["coordinates"].length == 2
        raise InvalidResponseError, "Location provider returned invalid geometry"
      end

      latitude, longitude = result.coordinates
      unless coordinate?(longitude, -180..180) && coordinate?(latitude, -90..90)
        raise InvalidResponseError, "Location provider returned invalid coordinates"
      end

      [ latitude.to_f, longitude.to_f ]
    end

    def coordinate?(value, range)
      value.is_a?(Numeric) && value.finite? && range.cover?(value)
    end
  end
end
