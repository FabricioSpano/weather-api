require "rails_helper"

RSpec.describe "Forecasts", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:address) { "10 Downing Street, London SW1A 2AA, United Kingdom" }
  let(:location_payload) { file_fixture("locations/success.json").read }
  let(:weather_payload) { file_fixture("weather/success.json").read }
  let(:location_request) do
    stub_request(:get, "https://photon.komoot.io/api/")
      .with(query: { q: address, lang: "en", limit: "5" })
      .to_return { { body: location_payload } }
  end
  let(:weather_request) do
    stub_request(:get, "https://api.open-meteo.com/v1/forecast")
      .with(query: {
        latitude: "51.5034878", longitude: "-0.1276965", current: "temperature_2m",
        daily: "temperature_2m_min,temperature_2m_max", temperature_unit: "celsius",
        forecast_days: "7", timezone: "auto", timeformat: "unixtime"
      }).to_return { { body: weather_payload } }
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    allow(OpenMeteo.configuration).to receive(:api_key).and_return(nil)
    location_request
    weather_request
  end

  describe "GET /forecast" do
    it "returns the resolved postal area, forecast and cache indicator as JSON" do
      get "/forecast", params: { address: }

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq("application/json")
      expect(response.headers.fetch("Cache-Control")).to include("no-store")
      expect(response.parsed_body).to include(
        "postal_code" => "SW1A 2AA", "country_code" => "GB", "country" => "United Kingdom", "cached" => false
      )
      expect(response.parsed_body.fetch("forecast")).to include("current_temperature" => 11.5, "temperature_unit" => "°C")
      expect(response.parsed_body.dig("forecast", "daily").length).to eq(7)
    end

    it "marks the second response as cached without calling either provider again" do
      get "/forecast", params: { address: }
      expect(response.parsed_body.fetch("cached")).to be(false)
      get "/forecast", params: { address: }

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch("cached")).to be(true)
      expect(location_request).to have_been_requested.once
      expect(weather_request).to have_been_requested.once
    end

    it "fetches a fresh forecast after thirty minutes" do
      travel_to(Time.utc(2026, 10, 29, 12)) do
        get "/forecast", params: { address: }
        travel 30.minutes
        get "/forecast", params: { address: }

        expect(response).to have_http_status(200)
        expect(response.parsed_body.fetch("cached")).to be(false)
        expect(location_request).to have_been_requested.twice
        expect(weather_request).to have_been_requested.twice
      end
    end

    [ nil, "", "   ", "a" * 501, [ "London", "Paris" ], { city: "London" } ].each do |invalid_address|
      it "returns 422 for invalid address #{invalid_address.inspect} without calling providers" do
        get "/forecast", params: { address: invalid_address }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_address")
        expect(location_request).not_to have_been_requested
        expect(weather_request).not_to have_been_requested
      end
    end

    it "returns 422 when the address parameter is missing" do
      get "/forecast"

      expect(response).to have_http_status(422)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_address")
    end

    context "when the address is ambiguous" do
      let(:address) { "Springfield" }
      let(:location_payload) { file_fixture("locations/ambiguous.json").read }

      it "asks for more details without choosing a candidate or calling weather" do
        get "/forecast", params: { address: }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("ambiguous_address")
        expect(response.parsed_body.dig("error", "message")).to include("city, region and country")
        expect(response.parsed_body.dig("error", "candidates").first).to include(
          "street" => nil, "city" => "Springfield", "state" => "Massachusetts",
          "country" => "United States", "country_code" => "US", "postal_code" => nil
        )
        expect(weather_request).not_to have_been_requested
      end
    end

    context "when refining an ambiguous address" do
      let(:address) { "1000 Caramuru, Ribeirão Preto, SP, Brasil" }
      let(:location_payload) { file_fixture("locations/caramuru.json").read }
      let(:weather_request) do
        stub_request(:get, "https://api.open-meteo.com/v1/forecast")
          .with(query: hash_including(latitude: "-21.1906117", longitude: "-47.8206526"))
          .to_return(body: weather_payload)
      end

      it "returns candidates, accepts explicit refinements, and caches only the resolved query" do
        resolved = JSON.parse(location_payload)
        resolved["features"] = resolved["features"].take(1)
        refined_request = stub_request(:get, "https://photon.komoot.io/api/")
          .with(query: { q: "#{address}, 14025119", lang: "en", limit: "5", countrycode: "BR" })
          .to_return(body: JSON.generate(resolved))

        get "/forecast", params: { address: }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "candidates").length).to eq(5)
        expect(response.parsed_body.dig("error", "candidates").first).to include(
          "street" => "Avenida Caramuru", "city" => "Ribeirão Preto", "country" => "Brazil",
          "country_code" => "BR", "postal_code" => "14025-119"
        )
        expect(weather_request).not_to have_been_requested

        get "/forecast", params: { address:, zipcode: "14025-119", country: "br" }

        expect(response).to have_http_status(200)
        expect(response.parsed_body).to include("postal_code" => "14025-119", "country_code" => "BR", "cached" => false)

        get "/forecast", params: { address:, zipcode: "14025119", country: "BR" }

        expect(response).to have_http_status(200)
        expect(response.parsed_body.fetch("cached")).to be(true)
        expect(refined_request).to have_been_requested.once
        expect(weather_request).to have_been_requested.once

        get "/forecast", params: { address: }

        expect(response).to have_http_status(422)
        expect(location_request).to have_been_requested.twice
        expect(weather_request).to have_been_requested.once
      end

      it "still returns 422 when the refined provider response contains multiple locations" do
        refined_request = stub_request(:get, "https://photon.komoot.io/api/")
          .with(query: { q: "#{address}, 14025119", lang: "en", limit: "5", countrycode: "BR" })
          .to_return(body: file_fixture("locations/caramuru_refined.json").read)

        get "/forecast", params: { address:, zipcode: "14025-119", country: "BR" }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("ambiguous_address")
        expect(response.parsed_body.dig("error", "candidates").length).to eq(2)
        expect(refined_request).to have_been_requested.once
        expect(weather_request).not_to have_been_requested
      end
    end

    [
      { zipcode: "" }, { zipcode: "---" }, { zipcode: [ "10001" ] }, { zipcode: { code: "10001" } },
      { country: "Brazil" }, { country: [ "BR" ] }, { country: { code: "BR" } }
    ].each do |filters|
      it "returns 422 for invalid refinements #{filters.inspect} without calling providers" do
        get "/forecast", params: { address:, **filters }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_address")
        expect(location_request).not_to have_been_requested
        expect(weather_request).not_to have_been_requested
      end
    end

    context "with only postal code and country" do
      let(:postal_request) do
        stub_request(:get, "https://photon.komoot.io/api/")
          .with(query: { q: "SW1A2AA", lang: "en", limit: "5", countrycode: "GB" })
          .to_return(body: file_fixture("locations/postal_code.json").read)
      end

      before { postal_request }

      it "returns a forecast and caches equivalent postal queries" do
        get "/forecast", params: { zipcode: "SW1A 2AA", country: "gb" }

        expect(response).to have_http_status(200)
        expect(response.parsed_body).to include("postal_code" => "SW1A 2AA", "country_code" => "GB", "cached" => false)

        get "/forecast", params: { address: "  ", zipcode: "sw1a-2aa", country: "GB" }

        expect(response).to have_http_status(200)
        expect(response.parsed_body.fetch("cached")).to be(true)
        expect(postal_request).to have_been_requested.once
        expect(location_request).not_to have_been_requested
        expect(weather_request).to have_been_requested.once
      end

      it "returns 422 for an unknown postal code without consulting weather" do
        stub_request(:get, "https://photon.komoot.io/api/")
          .with(query: { q: "SW1A2AA", lang: "en", limit: "5", countrycode: "GB" })
          .to_return(body: JSON.generate(type: "FeatureCollection", features: []))

        get "/forecast", params: { zipcode: "SW1A2AA", country: "GB" }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("address_not_found")
        expect(weather_request).not_to have_been_requested
      end

      it "preserves the upstream timeout response for a postal lookup" do
        stub_request(:get, "https://photon.komoot.io/api/")
          .with(query: { q: "SW1A2AA", lang: "en", limit: "5", countrycode: "GB" })
          .to_raise(Net::ReadTimeout)

        get "/forecast", params: { zipcode: "SW1A2AA", country: "GB" }

        expect(response).to have_http_status(504)
        expect(response.parsed_body.dig("error", "code")).to eq("upstream_timeout")
        expect(weather_request).not_to have_been_requested
      end
    end

    [
      { zipcode: "10001" }, { country: "US" }, { zipcode: "", country: "US" },
      { zipcode: "10001", country: "" }, { zipcode: [ "10001" ], country: "US" },
      { zipcode: "10001", country: { code: "US" } }, { address: [ "London" ], zipcode: "SW1A2AA", country: "GB" }
    ].each do |input|
      it "rejects missing or invalid postal fields without an address: #{input.inspect}" do
        get "/forecast", params: input

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_address")
        expect(location_request).not_to have_been_requested
        expect(weather_request).not_to have_been_requested
        expect(WebMock).not_to have_requested(:get, /photon/)
      end
    end

    context "when no location matches" do
      let(:location_payload) { JSON.generate(type: "FeatureCollection", features: []) }

      it "returns 422 with an address-not-found code" do
        get "/forecast", params: { address: }

        expect(response).to have_http_status(422)
        expect(response.parsed_body.dig("error", "code")).to eq("address_not_found")
        expect(weather_request).not_to have_been_requested
      end
    end

    context "when a provider returns malformed data" do
      let(:weather_payload) { "private upstream response body" }

      it "returns 502 without exposing the provider body" do
        get "/forecast", params: { address: }

        expect(response).to have_http_status(502)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_response")
        expect(response.body).not_to include(weather_payload)
      end
    end

    it "returns 504 for a weather timeout and retries successfully on the next request" do
      stub_request(:get, "https://api.open-meteo.com/v1/forecast").with(query: hash_including(current: "temperature_2m"))
        .to_raise(Net::ReadTimeout).then.to_return(body: weather_payload)

      get "/forecast", params: { address: }
      expect(response).to have_http_status(504)
      expect(response.parsed_body.dig("error", "code")).to eq("upstream_timeout")
      get "/forecast", params: { address: }

      expect(response).to have_http_status(200)
      expect(response.parsed_body.fetch("cached")).to be(false)
      expect(location_request).to have_been_requested.once
      expect(weather_request).to have_been_requested.twice
    end

    context "with a cache that drops writes" do
      let(:cache) { ActiveSupport::Cache::NullStore.new }

      it "continues returning successful uncached forecasts" do
        2.times do
          get "/forecast", params: { address: }

          expect(response).to have_http_status(200)
          expect(response.parsed_body.fetch("cached")).to be(false)
        end
      end
    end
  end

  describe "domain error mapping" do
    let(:service) { instance_double(Forecasts::Fetch) }

    before { allow(Forecasts::Fetch).to receive(:new).and_return(service) }

    [
      [ Locations::Client::InvalidAddressError, 422, "invalid_address" ],
      [ Locations::Client::NotFoundError, 422, "address_not_found" ],
      [ Locations::Client::AmbiguousAddressError, 422, "ambiguous_address" ],
      [ Weather::Client::InvalidCoordinatesError, 422, "invalid_coordinates" ],
      [ Locations::Client::InvalidResponseError, 502, "invalid_response" ],
      [ Weather::Client::InvalidResponseError, 502, "invalid_response" ],
      [ Locations::Client::TimeoutError, 504, "upstream_timeout" ],
      [ Weather::Client::TimeoutError, 504, "upstream_timeout" ],
      [ Locations::Client::RateLimitError, 503, "upstream_rate_limited" ],
      [ Weather::Client::RateLimitError, 503, "upstream_rate_limited" ],
      [ Locations::Client::UnavailableError, 503, "upstream_unavailable" ],
      [ Weather::Client::UnavailableError, 503, "upstream_unavailable" ]
    ].each do |error_class, status, code|
      it "maps #{error_class} to HTTP #{status}" do
        allow(service).to receive(:call).with(address:, zipcode: nil, country: nil).and_raise(error_class, "Safe domain error")

        get "/forecast", params: { address: }

        expect(response).to have_http_status(status)
        expect(response.parsed_body).to eq("error" => { "code" => code, "message" => "Safe domain error" })
        expect(response.headers.fetch("Cache-Control")).to include("no-store")
      end
    end

    it "handles subclasses through the Rails rescue mechanism" do
      error_class = Class.new(Weather::Client::TimeoutError)
      allow(service).to receive(:call).and_raise(error_class, "Weather timed out")

      get "/forecast", params: { address: }

      expect(response).to have_http_status(504)
      expect(response.parsed_body.dig("error", "code")).to eq("upstream_timeout")
    end

    it "does not hide unexpected programming errors" do
      allow(service).to receive(:call).and_raise(StandardError, "Unexpected bug")

      expect { get "/forecast", params: { address: } }.to raise_error(StandardError, "Unexpected bug")
    end
  end
end
