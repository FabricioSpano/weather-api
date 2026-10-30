require "rails_helper"

RSpec.describe Weather::Client do
  subject(:lookup) { client.call(latitude:, longitude:) }

  let(:client) { described_class.new }
  let(:latitude) { 51.5034878 }
  let(:longitude) { -0.1276965 }
  let(:host) { described_class::DEFAULT_HOST }
  let(:api_key) { nil }
  let(:payload) { JSON.parse(file_fixture("weather/success.json").read) }
  let(:body) { JSON.generate(payload) }
  let(:status) { 200 }
  let(:query) do
    {
      latitude: latitude.to_s, longitude: longitude.to_s,
      current: "temperature_2m", daily: "temperature_2m_min,temperature_2m_max",
      temperature_unit: "celsius", forecast_days: "7", timezone: "auto", timeformat: "unixtime"
    }.merge({ apikey: api_key }.compact)
  end
  let(:provider_request) do
    stub_request(:get, "https://#{host}/v1/forecast")
      .with(query:, headers: { "Accept" => "application/json", "User-Agent" => Weather::Connection::USER_AGENT })
      .to_return { { status:, body:, headers: { "Content-Type" => "application/json" } } }
  end

  before do
    allow(OpenMeteo.configuration).to receive(:api_key).and_return(api_key)
    provider_request
  end

  it "returns current conditions and seven daily forecasts from a captured provider response" do
    expect(lookup.to_h).to eq(
      current_temperature: 11.5, temperature_unit: "°C", current_time: "2026-10-30T01:45:00Z",
      timezone: "Europe/London", utc_offset_seconds: 0,
      daily: [
        { date: "2026-10-30", temperature_min: 10.5, temperature_max: 15.3 },
        { date: "2026-10-31", temperature_min: 10.0, temperature_max: 15.1 },
        { date: "2026-11-01", temperature_min: 8.3, temperature_max: 11.2 },
        { date: "2026-11-02", temperature_min: 8.3, temperature_max: 12.5 },
        { date: "2026-11-03", temperature_min: 8.7, temperature_max: 13.5 },
        { date: "2026-11-04", temperature_min: 8.1, temperature_max: 11.6 },
        { date: "2026-11-05", temperature_min: 8.2, temperature_max: 11.2 }
      ]
    )
    expect(provider_request).to have_been_requested.once
  end

  it "configures actual Net::HTTP connection, read and write timeouts and disables native retries" do
    transport = nil
    allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *arguments|
      transport = original.call(*arguments)
    end

    lookup

    expect(transport.open_timeout).to eq(2)
    expect(transport.read_timeout).to eq(3)
    expect(transport.write_timeout).to eq(3)
    expect(transport.max_retries).to eq(0)
  end

  context "with a different provider host" do
    let(:host) { "weather.example.test" }
    let(:client) { described_class.new(host:) }

    it "uses the configured host" do
      lookup

      expect(provider_request).to have_been_requested.once
    end
  end

  context "with an API key configured for the SDK" do
    let(:api_key) { "example-test-key" }

    it "forwards the configured API key" do
      lookup

      expect(provider_request).to have_been_requested.once
    end
  end

  it "does not change the SDK's global host or timeouts" do
    original_host = OpenMeteo.configuration.host
    original_timeouts = OpenMeteo.configuration.timeouts.dup

    described_class.new(host: "another-weather.example.test")
    lookup

    expect(OpenMeteo.configuration.host).to eq(original_host)
    expect(OpenMeteo.configuration.timeouts).to eq(original_timeouts)
  end

  [ nil, "", "bad host", "https://weather.example.test", "weather.example.test/path", "user@weather.example.test" ].each do |invalid_host|
    it "rejects invalid host #{invalid_host.inspect}" do
      expect { described_class.new(host: invalid_host) }.to raise_error(ArgumentError)
      expect(provider_request).not_to have_been_requested
    end
  end

  [ nil, false, "51.5", [], Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 1), -90.1, 90.1 ].each do |invalid_latitude|
    it "rejects latitude #{invalid_latitude.inspect} before requesting the provider" do
      expect { client.call(latitude: invalid_latitude, longitude:) }.to raise_error(described_class::InvalidCoordinatesError)
      expect(provider_request).not_to have_been_requested
    end
  end

  [ nil, false, "-0.1", {}, Float::NAN, Float::INFINITY, -180.1, 180.1 ].each do |invalid_longitude|
    it "rejects longitude #{invalid_longitude.inspect} before requesting the provider" do
      expect { client.call(latitude:, longitude: invalid_longitude) }.to raise_error(described_class::InvalidCoordinatesError)
      expect(provider_request).not_to have_been_requested
    end
  end

  [ [ -90.0, -180.0 ], [ 90.0, 180.0 ], [ 0.0, 0.0 ] ].each do |latitude_value, longitude_value|
    context "with boundary coordinates #{latitude_value}, #{longitude_value}" do
      let(:latitude) { latitude_value }
      let(:longitude) { longitude_value }

      it "accepts valid coordinate boundaries" do
        expect(lookup.current_temperature).to eq(11.5)
      end
    end
  end

  [ 0, -12.5 ].each do |temperature|
    it "accepts current temperature #{temperature}" do
      payload["current"]["temperature_2m"] = temperature

      expect(lookup.current_temperature).to eq(temperature.to_f)
    end
  end

  context "when the forecast crosses a daylight saving transition" do
    let(:latitude) { 40.7128 }
    let(:longitude) { -74.006 }
    let(:payload) { JSON.parse(file_fixture("weather/daylight_saving.json").read) }

    it "preserves the provider's daily dates using its fixed UTC offset" do
      expect(lookup.timezone).to eq("America/New_York")
      expect(lookup.utc_offset_seconds).to eq(-14_400)
      expect(lookup.daily.map { |day| day.fetch(:date) }).to eq(
        %w[2026-10-29 2026-10-30 2026-10-31 2026-11-01 2026-11-02 2026-11-03 2026-11-04]
      )
    end
  end

  [ "", "not JSON", "null", "[]", "true", "42", '{"error":true,"reason":"upstream failure"}' ].each do |invalid_body|
    context "with malformed response #{invalid_body.inspect}" do
      let(:body) { invalid_body }

      it "rejects an invalid provider response" do
        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  %w[current current_units daily daily_units].each do |field|
    [ nil, [], "wrong type" ].each do |invalid_value|
      it "rejects #{field} with value #{invalid_value.inspect}" do
        payload[field] = invalid_value

        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  %w[current_units daily_units].each do |field|
    it "rejects an unexpected time unit in #{field}" do
      payload[field]["time"] = "iso8601"

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ [ "current_units", "temperature_2m" ], [ "daily_units", "temperature_2m_min" ], [ "daily_units", "temperature_2m_max" ] ].each do |group, field|
    [ nil, "°F" ].each do |invalid_unit|
      it "rejects #{group}.#{field} with unit #{invalid_unit.inspect}" do
        payload[group][field] = invalid_unit

        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  [ nil, "", 123, "Not/A_Timezone" ].each do |invalid_timezone|
    it "rejects timezone #{invalid_timezone.inspect}" do
      payload["timezone"] = invalid_timezone

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ nil, "0", 0.5, -86_400, 86_400 ].each do |invalid_offset|
    it "rejects UTC offset #{invalid_offset.inspect}" do
      payload["utc_offset_seconds"] = invalid_offset

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ nil, "11.5", false, [], {} ].each do |invalid_temperature|
    it "rejects current temperature #{invalid_temperature.inspect}" do
      payload["current"]["temperature_2m"] = invalid_temperature

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ nil, "1793324700", false, 0, -1, 12.5 ].each do |invalid_time|
    it "rejects current timestamp #{invalid_time.inspect}" do
      payload["current"]["time"] = invalid_time

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  %w[time temperature_2m_min temperature_2m_max].each do |field|
    [ nil, {}, [], [ 1 ] ].each do |invalid_values|
      it "rejects incomplete daily #{field} values #{invalid_values.inspect}" do
        payload["daily"][field] = invalid_values

        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  %w[temperature_2m_min temperature_2m_max].each do |field|
    it "validates temperatures throughout all forecast days for #{field}" do
      payload["daily"][field][-1] = nil

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  it "rejects an inverted daily temperature range" do
    payload["daily"]["temperature_2m_min"][-1] = payload["daily"]["temperature_2m_max"][-1] + 1

    expect { lookup }.to raise_error(described_class::InvalidResponseError)
  end

  it "rejects a missing daily timestamp" do
    payload["daily"]["time"][-1] = nil

    expect { lookup }.to raise_error(described_class::InvalidResponseError)
  end

  it "rejects duplicate daily dates" do
    payload["daily"]["time"][-1] = payload["daily"]["time"][-2]

    expect { lookup }.to raise_error(described_class::InvalidResponseError)
  end

  it "rejects gaps in the daily date sequence" do
    payload["daily"]["time"][-1] += 86_400

    expect { lookup }.to raise_error(described_class::InvalidResponseError)
  end

  [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout ].each do |timeout|
    it "translates #{timeout} and makes only one request" do
      stub_request(:get, "https://#{host}/v1/forecast").with(query:).to_raise(timeout)

      expect { lookup }.to raise_error(described_class::TimeoutError)
      expect(provider_request).to have_been_requested.once
    end
  end

  [ SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse ].each do |network_error|
    it "translates #{network_error} without exposing the underlying exception or retrying" do
      stub_request(:get, "https://#{host}/v1/forecast").with(query:).to_raise(network_error)

      expect { lookup }.to raise_error(described_class::UnavailableError, "Weather provider is unavailable")
      expect(provider_request).to have_been_requested.once
    end
  end

  context "when the provider is rate limited" do
    let(:status) { 429 }
    let(:body) { "Too many requests" }

    it "raises a rate limit error without trying to decode the error body" do
      expect { lookup }.to raise_error(described_class::RateLimitError)
      expect(provider_request).to have_been_requested.once
    end
  end

  [ 301, 400, 401, 403, 404, 500, 502, 503 ].each do |http_status|
    context "when the provider returns HTTP #{http_status}" do
      let(:status) { http_status }
      let(:body) { "Provider error body" }

      it "raises an unavailable error without parsing, following redirects or retrying" do
        expect { lookup }.to raise_error(described_class::UnavailableError)
        expect(provider_request).to have_been_requested.once
      end
    end
  end
end
