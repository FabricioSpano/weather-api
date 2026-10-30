require "digest"
require "json"

module Forecasts
  class Fetch
    Result = Data.define(:postal_code, :country, :country_code, :forecast, :cached)

    CACHE_TTL = 30.minutes
    CACHE_VERSION = "v1".freeze
    LOCATION_CACHE_VERSION = "v2".freeze

    def initialize(locations: Locations::Client.new, weather: Weather::Client.new, cache: Rails.cache)
      @locations = locations
      @weather = weather
      @cache = cache
    end

    def call(address: nil, zipcode: nil, country: nil)
      filters = Locations::Client.normalize_filters(zipcode:, country:)
      address = Locations::Client.normalize_address(address, filters:)
      location = @cache.fetch(location_key(address, filters), expires_in: CACHE_TTL) do
        @locations.call(address:, **filters).to_h
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

    def location_key(address, filters)
      query = JSON.generate([ address&.downcase, filters ])
      [ "locations", LOCATION_CACHE_VERSION, Digest::SHA256.hexdigest(query) ]
    end

    def forecast_key(location)
      postal_code = location.fetch(:postal_code).gsub(/[[:space:]-]/, "").upcase
      [ "forecasts", CACHE_VERSION, location.fetch(:country_code).upcase, postal_code ]
    end
  end
end
