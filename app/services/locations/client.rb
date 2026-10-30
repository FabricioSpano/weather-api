require "geocoder"
require "active_support/core_ext/string/filters"

module Locations
  class Client
    class Error < StandardError; end
    class InvalidAddressError < Error; end
    class NotFoundError < Error; end
    class AmbiguousAddressError < Error
      attr_reader :candidates

      def initialize(message = "Address is ambiguous; include street number, city, region and country, or refine with zipcode and country", candidates: [])
        super(message)
        @candidates = candidates
      end
    end
    class InvalidResponseError < Error; end
    class TimeoutError < Error; end
    class RateLimitError < Error; end
    class UnavailableError < Error; end

    Location = Data.define(:postal_code, :country, :country_code, :latitude, :longitude)

    DEFAULT_ENDPOINT = "https://photon.komoot.io/api/".freeze
    USER_AGENT = "WeatherApi/1.0 (https://github.com/FabricioSpano/weather-api)".freeze
    CANDIDATE_LIMIT = 5

    def self.normalize_filters(zipcode: nil, country: nil)
      filters = { zipcode:, country: }.compact
      filters.each do |name, value|
        unless value.is_a?(String) && value.valid_encoding? && value.length <= 32 && !value.strip.empty?
          raise InvalidAddressError, "#{name} must be a nonblank string of at most 32 characters"
        end
      end
      filters.transform_values! { |value| value.strip.upcase }

      if filters[:country] && !filters[:country].match?(/\A[A-Z]{2}\z/)
        raise InvalidAddressError, "country must be a two-letter country code, such as BR, GB or US"
      end
      if filters[:zipcode]
        filters[:zipcode] = filters[:zipcode].gsub(/[[:space:]-]/, "")
        unless filters[:zipcode].match?(/\A[[:alnum:]]+\z/)
          raise InvalidAddressError, "zipcode must contain letters, digits, spaces or hyphens"
        end
      end

      filters
    end

    def self.normalize_address(address, filters:)
      unless address.nil? || (address.is_a?(String) && address.valid_encoding? && address.length <= 500)
        raise InvalidAddressError, "Provide an address with at most 500 characters"
      end

      normalized = address&.squish.presence
      if normalized.nil? && !(filters[:zipcode] && filters[:country])
        raise InvalidAddressError, "Provide an address or both zipcode and country"
      end

      normalized
    end

    def initialize(endpoint: ENV.fetch("LOCATIONS_URL", DEFAULT_ENDPOINT))
      uri = URI(endpoint)
      unless %w[http https].include?(uri.scheme) && uri.host
        raise ArgumentError, "LOCATIONS_URL must be an HTTP or HTTPS URL"
      end

      @lookup = PhotonLookup.new(endpoint:, headers: { "Accept" => "application/json", "User-Agent" => USER_AGENT })
    end

    def call(address: nil, zipcode: nil, country: nil)
      filters = self.class.normalize_filters(zipcode:, country:)
      address = self.class.normalize_address(address, filters:)
      if address && Geocoder::Query.new(address, lookup: :photon, street_address: true).reverse_geocode?
        raise InvalidAddressError, "Provide a street address instead of coordinates"
      end

      search = [ address, filters[:zipcode] ].compact.join(", ")
      query = Geocoder::Query.new(search, lookup: :photon, street_address: true,
        limit: CANDIDATE_LIMIT, language: "en", params: { countrycode: filters[:country] })
      results = @lookup.search(query).map { |result| [ result, candidate(result) ] }
      results.select! { |_, details| matches_filters?(details, filters) }
      raise NotFoundError, "No location found for this address" if results.empty?
      if results.length > 1
        raise AmbiguousAddressError.new(candidates: results.map(&:last))
      end

      normalize(results.fetch(0).first)
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

    def properties(result)
      feature = result.data
      unless feature.is_a?(Hash) && feature["type"] == "Feature" && feature["properties"].is_a?(Hash)
        raise InvalidResponseError, "Location provider returned an invalid feature"
      end

      feature["properties"]
    end

    def candidate(result)
      fields = properties(result)
      street = optional_text(fields["street"])
      street ||= optional_text(fields["name"]) if fields["type"] == "street"
      {
        street:, house_number: optional_text(fields["housenumber"]),
        city: optional_text(fields["city"]), state: optional_text(fields["state"]),
        country: optional_text(fields["country"]), country_code: optional_text(fields["countrycode"])&.upcase,
        postal_code: optional_text(postal_code(result))
      }
    end

    def matches_filters?(details, filters)
      filters.all? do |name, expected|
        value = details[name == :zipcode ? :postal_code : :country_code]
        # Missing metadata cannot rule a candidate out; it must not manufacture a unique match.
        value.nil? || value.gsub(/[[:space:]-]/, "").upcase == expected
      end
    end

    def optional_text(value)
      value.strip.presence if value.is_a?(String)
    end

    def postal_code(result)
      fields = properties(result)
      # Photon stores the code as the name for postal-area features.
      result.postal_code || (fields["name"] if fields["osm_key"] == "place" && fields["osm_value"] == "postcode")
    end

    def normalize(result)
      properties = properties(result)
      postal_code = text(postal_code(result))
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
