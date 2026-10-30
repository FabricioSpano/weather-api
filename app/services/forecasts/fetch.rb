require "digest"
require "active_support/core_ext/string/filters"

module Forecasts
  class Fetch
    Result = Data.define(:postal_code, :country, :country_code, :forecast, :cached)

    CACHE_TTL = 30.minutes
    CACHE_VERSION = "v1".freeze

    def initialize(locations: Locations::Client.new, weather: Weather::Client.new, cache: Rails.cache)
      @locations = locations
      @weather = weather
      @cache = cache
    end

    def call(address:)
      address = normalize_address(address)
      location = @cache.fetch(location_key(address), expires_in: CACHE_TTL) do
        @locations.call(address:).to_h
      end

      cached = true
      forecast = @cache.fetch(forecast_key(location), expires_in: CACHE_TTL) do
        cached = false
        @weather.call(latitude: location.fetch(:latitude), longitude: location.fetch(:longitude)).to_h
      end

      Result.new(
        postal_code: location.fetch(:postal_code), country: location.fetch(:country),
        country_code: location.fetch(:country_code), forecast:, cached:
      )
    end

    private

    def normalize_address(address)
      unless address.is_a?(String) && address.valid_encoding? && address.length <= 500
        raise Locations::Client::InvalidAddressError, "Provide an address with at most 500 characters"
      end

      normalized = address.squish
      if normalized.empty?
        raise Locations::Client::InvalidAddressError, "Provide an address with at most 500 characters"
      end

      normalized
    end

    def location_key(address)
      [ "locations", CACHE_VERSION, Digest::SHA256.hexdigest(address.downcase) ]
    end

    def forecast_key(location)
      postal_code = location.fetch(:postal_code).gsub(/[[:space:]-]/, "").upcase
      [ "forecasts", CACHE_VERSION, location.fetch(:country_code).upcase, postal_code ]
    end
  end
end
