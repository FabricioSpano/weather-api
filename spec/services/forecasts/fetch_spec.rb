require "rails_helper"

RSpec.describe Forecasts::Fetch do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:address) { "10 Downing Street, London SW1A 2AA, United Kingdom" }

  context "with provider doubles" do
    subject(:lookup) { service.call(address:) }

    let(:service) { described_class.new(locations:, weather:, cache:) }
    let(:locations) { instance_double(Locations::Client) }
    let(:weather) { instance_double(Weather::Client) }
    let(:location) do
      Locations::Client::Location.new(
        postal_code: "SW1A 2AA", country: "United Kingdom", country_code: "GB",
        latitude: 51.5034878, longitude: -0.1276965
      )
    end
    let(:forecast) do
      Weather::Client::Forecast.new(
        current_temperature: 11.5, temperature_unit: "°C", current_time: "2026-10-30T01:45:00Z",
        timezone: "Europe/London", utc_offset_seconds: 0,
        daily: 7.times.map do |index|
          { date: (Date.new(2026, 10, 30) + index).iso8601, temperature_min: 10.0, temperature_max: 15.0 }
        end
      )
    end

    before do
      allow(locations).to receive(:call).with(address:).and_return(location)
      allow(weather).to receive(:call).with(latitude: location.latitude, longitude: location.longitude).and_return(forecast)
    end

    it "returns country, postal code and a fresh forecast" do
      expect(lookup.to_h).to eq(
        postal_code: "SW1A 2AA", country: "United Kingdom", country_code: "GB",
        forecast: forecast.to_h, cached: false
      )
    end

    it "reuses the location and forecast on a repeated request" do
      first = lookup
      second = service.call(address:)

      expect(first.cached).to be(false)
      expect(second.cached).to be(true)
      expect(second.forecast).to eq(first.forecast)
      expect(locations).to have_received(:call).once
      expect(weather).to have_received(:call).once
    end

    it "stores plain hashes rather than client result objects or cache-hit metadata" do
      lookup

      stored_forecast = cache.read([ "forecasts", "v1", "GB", "SW1A2AA" ])
      expect(stored_forecast).to eq(forecast.to_h)
      expect(stored_forecast).to be_a(Hash)
      expect(stored_forecast).not_to have_key(:cached)
    end

    it "shares cached results with another service instance" do
      lookup
      other_locations = instance_double(Locations::Client)
      other_weather = instance_double(Weather::Client)
      other_service = described_class.new(locations: other_locations, weather: other_weather, cache:)

      expect(other_service.call(address:).cached).to be(true)
    end

    it "normalizes whitespace before location lookup and case in the location cache key" do
      service.call(address: "  10   Downing Street, London SW1A 2AA, United Kingdom  ")
      result = service.call(address: address.upcase)

      expect(result.cached).to be(true)
      expect(locations).to have_received(:call).with(address:).once
      expect(weather).to have_received(:call).once
    end

    it "does not reuse an unrefined location for a refined request, but shares its postal forecast" do
      allow(locations).to receive(:call).with(address:, zipcode: "SW1A2AA", country: "GB").and_return(location)

      lookup
      result = service.call(address:, zipcode: "SW1A 2AA", country: "GB")

      expect(result.cached).to be(true)
      expect(locations).to have_received(:call).with(address:).once
      expect(locations).to have_received(:call).with(address:, zipcode: "SW1A2AA", country: "GB").once
      expect(weather).to have_received(:call).once
    end

    it "shares a location cache entry between equivalent refinement formats" do
      allow(locations).to receive(:call).with(address:, zipcode: "SW1A2AA", country: "GB").and_return(location)

      service.call(address:, zipcode: " sw1a-2aa ", country: " gb ")
      result = service.call(address: address.upcase, zipcode: "SW1A 2AA", country: "GB")

      expect(result.cached).to be(true)
      expect(locations).to have_received(:call).once
      expect(weather).to have_received(:call).once
    end

    context "with postal code and country instead of an address" do
      before do
        allow(locations).to receive(:call).with(address: nil, zipcode: "SW1A2AA", country: "GB").and_return(location)
      end

      it "normalizes postal inputs and reuses their location and forecast" do
        first = service.call(zipcode: "sw1a-2aa", country: "gb")
        second = service.call(address: "  ", zipcode: "SW1A 2AA", country: "GB")

        expect(first.cached).to be(false)
        expect(second.cached).to be(true)
        expect(locations).to have_received(:call).with(address: nil, zipcode: "SW1A2AA", country: "GB").once
        expect(weather).to have_received(:call).once
      end

      it "shares forecasts with an address lookup without sharing the location key" do
        lookup
        result = service.call(zipcode: "SW1A2AA", country: "GB")

        expect(result.cached).to be(true)
        expect(locations).to have_received(:call).twice
        expect(weather).to have_received(:call).once
      end

      it "validates postal fields before reading an existing cache entry" do
        service.call(zipcode: "SW1A2AA", country: "GB")
        expect(cache).not_to receive(:fetch)

        expect { service.call(zipcode: "SW1A2AA") }.to raise_error(Locations::Client::InvalidAddressError)
      end

      it "expires postal lookups and forecasts after thirty minutes" do
        travel_to(Time.utc(2026, 10, 30, 12)) do
          service.call(zipcode: "SW1A2AA", country: "GB")
          travel 30.minutes

          expect(service.call(zipcode: "SW1A2AA", country: "GB").cached).to be(false)
          expect(locations).to have_received(:call).twice
          expect(weather).to have_received(:call).twice
        end
      end
    end

    [ {}, { zipcode: "SW1A2AA" }, { country: "GB" } ].each do |input|
      it "rejects missing address and incomplete postal fields #{input.inspect} before accessing the cache" do
        expect(cache).not_to receive(:fetch)

        expect { service.call(**input) }.to raise_error(Locations::Client::InvalidAddressError)
        expect(locations).not_to have_received(:call)
        expect(weather).not_to have_received(:call)
      end
    end

    it "keeps different refinements of the same address isolated" do
      other_location = location.with(postal_code: "10001", country: "United States", country_code: "US",
        latitude: 40.75, longitude: -73.99)
      allow(locations).to receive(:call).with(address:, zipcode: "SW1A2AA", country: "GB").and_return(location)
      allow(locations).to receive(:call).with(address:, zipcode: "10001", country: "US").and_return(other_location)
      allow(weather).to receive(:call).with(latitude: other_location.latitude, longitude: other_location.longitude)
        .and_return(forecast)

      service.call(address:, zipcode: "SW1A2AA", country: "GB")
      result = service.call(address:, zipcode: "10001", country: "US")

      expect(result.country_code).to eq("US")
      expect(result.postal_code).to eq("10001")
      expect(result.cached).to be(false)
      expect(locations).to have_received(:call).twice
      expect(weather).to have_received(:call).twice
    end

    [ { zipcode: [] }, { country: "Brazil" }, { zipcode: "---" } ].each do |filters|
      it "validates refinements #{filters.inspect} before accessing the cache" do
        expect(cache).not_to receive(:fetch)

        expect { service.call(address:, **filters) }.to raise_error(Locations::Client::InvalidAddressError)
        expect(locations).not_to have_received(:call)
        expect(weather).not_to have_received(:call)
      end
    end

    it "uses an address digest instead of including a raw street address in cache keys" do
      expect(cache).to receive(:fetch).with(
        [ "locations", "v2", Digest::SHA256.hexdigest(JSON.generate([ address.downcase, {} ])) ], expires_in: 30.minutes
      ).and_call_original
      allow(cache).to receive(:fetch).with([ "forecasts", "v1", "GB", "SW1A2AA" ], expires_in: 30.minutes).and_call_original

      lookup
    end

    it "shares a forecast with another address in the same postal area" do
      other_address = "Another address in the same postal area"
      other_location = location.with(latitude: 51.504, longitude: -0.128)
      allow(locations).to receive(:call).with(address: other_address).and_return(other_location)

      lookup
      result = service.call(address: other_address)

      expect(result.cached).to be(true)
      expect(result.forecast).to eq(forecast.to_h)
      expect(locations).to have_received(:call).twice
      expect(weather).to have_received(:call).once
    end

    it "normalizes spaces, hyphens and letter case in postal cache keys" do
      other_address = "An alternative spelling of the address"
      allow(locations).to receive(:call).with(address: other_address)
        .and_return(location.with(postal_code: "sw1a-2aa", country_code: "gb"))

      lookup

      expect(service.call(address: other_address).cached).to be(true)
      expect(weather).to have_received(:call).once
    end

    context "with a postal code shared by different countries" do
      let(:location) do
        Locations::Client::Location.new(
          postal_code: "10001", country: "United States", country_code: "US",
          latitude: 40.75, longitude: -73.99
        )
      end

      it "fetches and stores separate forecasts" do
        other_address = "An address in Caceres, Spain"
        other_location = location.with(country: "Spain", country_code: "ES", latitude: 39.48, longitude: -6.37)
        other_forecast = forecast.with(current_temperature: 20.0)
        allow(locations).to receive(:call).with(address: other_address).and_return(other_location)
        allow(weather).to receive(:call).with(latitude: other_location.latitude, longitude: other_location.longitude)
          .and_return(other_forecast)

        lookup
        result = service.call(address: other_address)

        expect(result.cached).to be(false)
        expect(result.country_code).to eq("ES")
        expect(result.forecast.fetch(:current_temperature)).to eq(20.0)
        expect(weather).to have_received(:call).twice
        expect(service.call(address:).forecast.fetch(:current_temperature)).to eq(11.5)
      end
    end

    context "with a postal code containing leading zeros" do
      let(:location) { super().with(postal_code: "00501", country: "United States", country_code: "US") }

      it "preserves leading zeros in the result and cache key" do
        expect(lookup.postal_code).to eq("00501")
        expect(cache.exist?([ "forecasts", "v1", "US", "00501" ])).to be(true)
      end
    end

    it "expires location and forecast data at thirty minutes" do
      travel_to(Time.utc(2026, 10, 29, 12)) do
        expect(lookup.cached).to be(false)
        travel 30.minutes

        expect(service.call(address:).cached).to be(false)
        expect(locations).to have_received(:call).twice
        expect(weather).to have_received(:call).twice
      end
    end

    it "does not extend expiration when a cached forecast is read" do
      travel_to(Time.utc(2026, 10, 29, 12)) do
        lookup
        travel 29.minutes
        expect(service.call(address:).cached).to be(true)
        travel 61.seconds

        expect(service.call(address:).cached).to be(false)
        expect(weather).to have_received(:call).twice
      end
    end

    [ nil, false, {}, [], "", " \n\t ", "\u00a0", "a" * 501, "\xff".force_encoding("UTF-8") ].each do |invalid_address|
      it "rejects invalid input #{invalid_address.inspect} before consulting cache or providers" do
        expect(cache).not_to receive(:fetch)

        expect { service.call(address: invalid_address) }.to raise_error(Locations::Client::InvalidAddressError)
        expect(locations).not_to have_received(:call)
        expect(weather).not_to have_received(:call)
      end
    end

    it "enforces the input length limit even when the normalized address is already cached" do
      lookup

      expect { service.call(address: " " * 501 + address) }.to raise_error(Locations::Client::InvalidAddressError)
      expect(weather).to have_received(:call).once
    end

    [
      Locations::Client::InvalidAddressError, Locations::Client::NotFoundError,
      Locations::Client::AmbiguousAddressError, Locations::Client::InvalidResponseError,
      Locations::Client::TimeoutError, Locations::Client::RateLimitError, Locations::Client::UnavailableError
    ].each do |error_class|
      it "propagates #{error_class} without caching the failure or consulting weather" do
        error = error_class.new("Location failed")
        allow(locations).to receive(:call).and_raise(error)

        2.times { expect { lookup }.to raise_error { |raised| expect(raised).to equal(error) } }

        expect(locations).to have_received(:call).twice
        expect(weather).not_to have_received(:call)
      end
    end

    [
      Weather::Client::InvalidCoordinatesError, Weather::Client::InvalidResponseError,
      Weather::Client::TimeoutError, Weather::Client::RateLimitError, Weather::Client::UnavailableError
    ].each do |error_class|
      it "propagates #{error_class} without caching the failure" do
        error = error_class.new("Weather failed")
        allow(weather).to receive(:call).and_raise(error)

        2.times { expect { lookup }.to raise_error { |raised| expect(raised).to equal(error) } }

        expect(locations).to have_received(:call).once
        expect(weather).to have_received(:call).twice
      end
    end

    it "recovers after a weather failure and caches only the successful retry" do
      attempts = 0
      allow(weather).to receive(:call) do
        attempts += 1
        raise Weather::Client::TimeoutError, "Weather timed out" if attempts == 1

        forecast
      end

      expect { lookup }.to raise_error(Weather::Client::TimeoutError)
      expect(service.call(address:).cached).to be(false)
      expect(service.call(address:).cached).to be(true)
      expect(locations).to have_received(:call).once
      expect(weather).to have_received(:call).twice
    end

    context "when cache reads miss and writes are dropped" do
      let(:cache) { ActiveSupport::Cache::NullStore.new }

      it "returns fresh forecasts with a truthful cache indicator" do
        expect(lookup.cached).to be(false)
        expect(service.call(address:).cached).to be(false)
        expect(weather).to have_received(:call).twice
      end
    end

    it "keeps cache-hit indicators separate for concurrent calls on the same instance" do
      lookup
      uncached_address = "A different postal area"
      uncached_location = location.with(postal_code: "SW1A 1AA", latitude: 51.50, longitude: -0.14)
      allow(locations).to receive(:call).with(address: uncached_address).and_return(uncached_location)
      entered = Queue.new
      release = Queue.new
      allow(weather).to receive(:call).with(latitude: uncached_location.latitude, longitude: uncached_location.longitude) do
        entered << true
        release.pop
        forecast
      end

      pending = Thread.new { service.call(address: uncached_address) }
      Timeout.timeout(2) { entered.pop }
      expect(service.call(address:).cached).to be(true)
      release << true
      expect(pending.join(2)).not_to be_nil
      expect(pending.value.cached).to be(false)
    ensure
      pending&.kill if pending&.alive?
    end
  end

  context "with the provider clients and stubbed HTTP" do
    subject(:lookup) { described_class.new(cache:).call(address:) }

    let(:location_payload) { file_fixture("locations/success.json").read }
    let(:weather_payload) { file_fixture("weather/success.json").read }
    let(:location_request) do
      stub_request(:get, "https://photon.komoot.io/api/")
        .with(query: { q: address, lang: "en", limit: "5" })
        .to_return(body: location_payload)
    end
    let(:weather_query) do
      {
        latitude: "51.5034878", longitude: "-0.1276965", current: "temperature_2m",
        daily: "temperature_2m_min,temperature_2m_max", temperature_unit: "celsius",
        forecast_days: "7", timezone: "auto", timeformat: "unixtime"
      }
    end
    let(:weather_request) do
      stub_request(:get, "https://api.open-meteo.com/v1/forecast")
        .with(query: weather_query).to_return(body: weather_payload)
    end

    before do
      allow(OpenMeteo.configuration).to receive(:api_key).and_return(nil)
      location_request
      weather_request
    end

    it "coordinates Geocoder, weather and cache using real client implementations" do
      first = lookup
      second = described_class.new(cache:).call(address:)

      expect(first.cached).to be(false)
      expect(second.cached).to be(true)
      expect(second.postal_code).to eq("SW1A 2AA")
      expect(second.forecast.fetch(:current_temperature)).to eq(11.5)
      expect(second.forecast.fetch(:daily).length).to eq(7)
      expect(location_request).to have_been_requested.once
      expect(weather_request).to have_been_requested.once
    end

    context "when the address is ambiguous" do
      let(:address) { "Springfield" }
      let(:location_payload) { file_fixture("locations/ambiguous.json").read }

      it "rejects the address without consulting weather or caching the failure" do
        2.times { expect { lookup }.to raise_error(Locations::Client::AmbiguousAddressError) }

        expect(location_request).to have_been_requested.twice
        expect(weather_request).not_to have_been_requested
      end
    end

    it "reuses successful location data after a weather timeout and retries the forecast on the next request" do
      stub_request(:get, "https://api.open-meteo.com/v1/forecast").with(query: weather_query)
        .to_raise(Net::ReadTimeout).then.to_return(body: weather_payload)

      expect { lookup }.to raise_error(Weather::Client::TimeoutError)
      expect(described_class.new(cache:).call(address:).cached).to be(false)
      expect(described_class.new(cache:).call(address:).cached).to be(true)
      expect(location_request).to have_been_requested.once
      expect(weather_request).to have_been_requested.twice
    end
  end
end
