require "rails_helper"

RSpec.describe Locations::Client do
  subject(:lookup) { client.call(address:) }

  let(:client) { described_class.new }
  let(:address) { "10 Downing Street, London SW1A 2AA, United Kingdom" }
  let(:endpoint) { described_class::DEFAULT_ENDPOINT }
  let(:payload) { JSON.parse(file_fixture("locations/success.json").read) }
  let(:body) { JSON.generate(payload) }
  let(:status) { 200 }
  let(:query) { { q: address, limit: "5", lang: "en" } }
  let(:provider_request) do
    stub_request(:get, endpoint)
      .with(query:,
            headers: { "Accept" => "application/json", "User-Agent" => described_class::USER_AGENT })
      .to_return { { status:, body:, headers: { "Content-Type" => "application/json" } } }
  end

  before { provider_request }

  it "returns the postal code, country and correctly ordered coordinates from a real provider response" do
    expect(lookup.to_h).to eq(
      postal_code: "SW1A 2AA", country: "United Kingdom", country_code: "GB",
      latitude: 51.5034878, longitude: -0.1276965
    )
  end

  it "bounds connection and response time and disables automatic retries" do
    expect(Net::HTTP).to receive(:start).with(
      "photon.komoot.io", 443,
      use_ssl: true, open_timeout: 2, read_timeout: 3, write_timeout: 3, max_retries: 0
    ).and_call_original

    lookup
  end

  it "preserves leading zeros in postal codes" do
    payload["features"][0]["properties"]["postcode"] = "00501"

    expect(lookup.postal_code).to eq("00501")
  end

  it "normalizes the country code" do
    payload["features"][0]["properties"]["countrycode"] = "gb"

    expect(lookup.country_code).to eq("GB")
  end

  context "with a configured provider endpoint" do
    let(:endpoint) { "https://locations.example.test/api/" }
    let(:client) { described_class.new(endpoint:) }

    it "uses the configured endpoint" do
      lookup

      expect(provider_request).to have_been_requested.once
    end
  end

  it "rejects an unsupported provider URL before making a request" do
    expect { described_class.new(endpoint: "file:///etc/passwd") }.to raise_error(ArgumentError, /HTTP or HTTPS/)
    expect(provider_request).not_to have_been_requested
  end

  [ nil, 42, [], {}, "", "   ", "a" * 501 ].each do |invalid_address|
    it "rejects invalid input #{invalid_address.inspect} without requesting the provider" do
      expect { client.call(address: invalid_address) }.to raise_error(described_class::InvalidAddressError)
      expect(provider_request).not_to have_been_requested
    end
  end

  it "trims the address before requesting the provider" do
    client.call(address: "  #{address}  ")

    expect(provider_request).to have_been_requested.once
  end

  it "rejects coordinates instead of silently switching to reverse geocoding" do
    expect { client.call(address: "51.5034878, -0.1276965") }
      .to raise_error(described_class::InvalidAddressError, /street address instead of coordinates/)
    expect(provider_request).not_to have_been_requested
  end

  context "when an address resembles an IP address" do
    let(:address) { "127.0.0.1" }

    it "keeps the lookup on the configured Photon provider" do
      lookup

      expect(provider_request).to have_been_requested.once
    end
  end

  it "keeps Geocoder's global configuration unchanged" do
    configuration = Geocoder.config.deep_dup

    lookup

    expect(Geocoder.config).to eq(configuration)
  end

  context "when another client uses a different endpoint" do
    let(:other_endpoint) { "https://other-locations.example.test/api/" }

    it "keeps client configuration isolated" do
      other_request = stub_request(:get, other_endpoint).with(query:).to_return(body:)
      other_client = described_class.new(endpoint: other_endpoint)

      other_client.call(address:)
      lookup

      expect(other_request).to have_been_requested.once
      expect(provider_request).to have_been_requested.once
    end
  end

  context "with an HTTP endpoint for a local Photon installation" do
    let(:endpoint) { "http://locations.example.test/api/" }
    let(:client) { described_class.new(endpoint:) }

    it "uses the configured protocol" do
      expect(Net::HTTP).to receive(:start).with(
        "locations.example.test", 80,
        use_ssl: false, open_timeout: 2, read_timeout: 3, write_timeout: 3, max_retries: 0
      ).and_call_original

      lookup
    end
  end

  context "when no locations match" do
    let(:payload) { { "type" => "FeatureCollection", "features" => [] } }

    it "raises a not found error" do
      expect { lookup }.to raise_error(described_class::NotFoundError)
    end
  end

  context "when the address is ambiguous" do
    let(:address) { "Springfield" }
    let(:payload) { JSON.parse(file_fixture("locations/ambiguous.json").read) }

    it "asks for more details instead of returning the first location" do
      expect { lookup }.to raise_error(described_class::AmbiguousAddressError, /city, region and country/)
    end

    it "provides address fields for the caller to refine, with nil for missing postal data" do
      expect { lookup }.to raise_error(described_class::AmbiguousAddressError) do |error|
        expect(error.candidates.first).to eq(
          street: nil, house_number: nil, city: "Springfield", state: "Massachusetts",
          country: "United States", country_code: "US", postal_code: nil
        )
        expect(error.candidates.length).to eq(2)
      end
    end

    it "still rejects ambiguity if only one of the candidates has a postal code" do
      payload["features"][0]["properties"]["postcode"] = "01103"

      expect { lookup }.to raise_error(described_class::AmbiguousAddressError)
    end
  end

  context "with postal and country refinements" do
    let(:address) { "1000 Caramuru, Ribeirão Preto, SP, Brasil" }
    let(:payload) { JSON.parse(file_fixture("locations/caramuru.json").read) }
    let(:query) { { q: "#{address}, 14025119", limit: "5", lang: "en", countrycode: "BR" } }

    it "filters all returned results rather than choosing the first candidate" do
      payload["features"].reverse!

      location = client.call(address:, zipcode: "14025-119", country: " br ")

      expect(location.postal_code).to eq("14025-119")
      expect(location.country_code).to eq("BR")
      expect(location.latitude).to eq(-21.1906117)
      expect(location.longitude).to eq(-47.8206526)
      expect(provider_request).to have_been_requested.once
    end

    it "returns not found when the supplied postal code excludes every result" do
      payload["features"].shift

      expect { client.call(address:, zipcode: "14025119", country: "BR") }
        .to raise_error(described_class::NotFoundError)
    end

    it "does not discard an unresolved candidate whose postal metadata is missing" do
      payload["features"][1]["properties"].delete("postcode")

      expect { client.call(address:, zipcode: "14025119", country: "BR") }
        .to raise_error(described_class::AmbiguousAddressError) do |error|
          expect(error.candidates.map { |candidate| candidate[:postal_code] }).to eq([ "14025-119", nil ])
        end
    end

    context "when distinct locations remain within the supplied postal area" do
      let(:payload) { JSON.parse(file_fixture("locations/caramuru_refined.json").read) }

      it "continues to return ambiguity and includes only candidates not ruled out by the filters" do
        expect { client.call(address:, zipcode: "14025119", country: "BR") }
          .to raise_error(described_class::AmbiguousAddressError) do |error|
            expect(error.candidates.length).to eq(2)
            expect(error.candidates.map { |candidate| candidate[:postal_code] }.uniq).to eq([ "14025-119" ])
            expect(error.candidates.first[:street]).to eq("Avenida Caramuru")
          end
      end
    end
  end

  context "with only postal code and country" do
    let(:payload) { JSON.parse(file_fixture("locations/postal_code.json").read) }
    let(:query) { { q: "SW1A2AA", limit: "5", lang: "en", countrycode: "GB" } }

    it "resolves a postal area using the provider's postcode feature name" do
      location = client.call(zipcode: " sw1a-2aa ", country: "gb")

      expect(location.to_h).to eq(
        postal_code: "SW1A 2AA", country: "United Kingdom", country_code: "GB",
        latitude: 51.5034878, longitude: -0.1276965
      )
      expect(provider_request).to have_been_requested.once
    end

    [ nil, "", " \n\t " ].each do |blank_address|
      it "accepts blank address #{blank_address.inspect} with both postal fields" do
        expect(client.call(address: blank_address, zipcode: "SW1A2AA", country: "GB").postal_code).to eq("SW1A 2AA")
      end
    end

    it "preserves leading zeros when querying a numeric postal code" do
      payload["features"][0]["properties"].merge!("name" => "00501", "country" => "United States", "countrycode" => "US")
      request = stub_request(:get, endpoint)
        .with(query: { q: "00501", limit: "5", lang: "en", countrycode: "US" }).to_return(body:)

      expect(client.call(zipcode: "00501", country: "US").postal_code).to eq("00501")
      expect(request).to have_been_requested.once
    end

    it "rejects fuzzy results for a different postal code" do
      payload["features"][0]["properties"]["name"] = "SW1A 1AA"

      expect { client.call(zipcode: "SW1A2AA", country: "GB") }.to raise_error(described_class::NotFoundError)
    end

    it "still returns candidates when more than one postal location matches" do
      other = Marshal.load(Marshal.dump(payload["features"][0]))
      other["geometry"]["coordinates"] = [ -0.12, 51.51 ]
      payload["features"] << other

      expect { client.call(zipcode: "SW1A2AA", country: "GB") }
        .to raise_error(described_class::AmbiguousAddressError) do |error|
          expect(error.candidates.map { |candidate| candidate[:postal_code] }).to eq([ "SW1A 2AA", "SW1A 2AA" ])
        end
    end

    it "does not mistake an unrelated feature name for a postal code" do
      payload["features"][0]["properties"]["osm_value"] = "city"

      expect { client.call(zipcode: "SW1A2AA", country: "GB") }.to raise_error(described_class::InvalidResponseError)
    end

    [ 42, false, [], {}, "a" * 501, "\xff".force_encoding("UTF-8") ].each do |invalid_address|
      it "rejects malformed address #{invalid_address.inspect} even with both postal fields" do
        expect { client.call(address: invalid_address, zipcode: "SW1A2AA", country: "GB") }
          .to raise_error(described_class::InvalidAddressError)
        expect(provider_request).not_to have_been_requested
      end
    end
  end

  [ {}, { zipcode: "SW1A2AA" }, { country: "GB" } ].each do |input|
    it "requires both postal fields when address is absent: #{input.inspect}" do
      expect { client.call(**input) }.to raise_error(described_class::InvalidAddressError, /address or both/)
      expect(provider_request).not_to have_been_requested
    end
  end

  context "with only a country refinement" do
    let(:query) { super().merge(countrycode: "GB") }

    it "sends the country restriction to Photon" do
      expect(client.call(address:, country: "gb").country_code).to eq("GB")
      expect(provider_request).to have_been_requested.once
    end

    it "checks the country even if the provider ignores the restriction" do
      payload["features"][0]["properties"]["countrycode"] = "US"

      expect { client.call(address:, country: "GB") }.to raise_error(described_class::NotFoundError)
    end
  end

  context "with only a postal refinement" do
    let(:query) { super().merge(q: "#{address}, SW1A2AA") }

    it "accepts international postal codes and normalizes their formatting" do
      expect(client.call(address:, zipcode: " sw1a-2aa ").postal_code).to eq("SW1A 2AA")
      expect(provider_request).to have_been_requested.once
    end

    it "still rejects coordinate input before appending the postal code" do
      expect { client.call(address: "51.5034878, -0.1276965", zipcode: "SW1A2AA") }
        .to raise_error(described_class::InvalidAddressError)
      expect(provider_request).not_to have_been_requested
    end
  end

  {
    zipcode: [ "", "   ", "---", "12/34", "a" * 33, 42, false, [], {}, "\xff".force_encoding("UTF-8") ],
    country: [ "", "   ", "Brazil", "B", "B-R", "a" * 33, 42, false, [], {}, "\xff".force_encoding("UTF-8") ]
  }.each do |field, values|
    values.each do |value|
      it "rejects invalid #{field} #{value.inspect} before making an HTTP request" do
        expect { client.call(address:, **{ field => value }) }.to raise_error(described_class::InvalidAddressError)
        expect(provider_request).not_to have_been_requested
      end
    end
  end

  [ "not JSON", "null", "[]", "{}", '{"type":"FeatureCollection","features":{}}' ].each do |invalid_body|
    context "with malformed response #{invalid_body.inspect}" do
      let(:body) { invalid_body }

      it "raises an invalid response error" do
        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  %w[postcode country countrycode].each do |field|
    [ nil, "", "   ", 123 ].each do |invalid_value|
      it "rejects #{field} with value #{invalid_value.inspect}" do
        payload["features"][0]["properties"][field] = invalid_value

        expect { lookup }.to raise_error(described_class::InvalidResponseError)
      end
    end
  end

  it "rejects a malformed country code" do
    payload["features"][0]["properties"]["countrycode"] = "GBR"

    expect { lookup }.to raise_error(described_class::InvalidResponseError)
  end

  [ nil, {}, { "type" => "Feature", "properties" => nil } ].each do |invalid_feature|
    it "rejects invalid feature #{invalid_feature.inspect}" do
      payload["features"] = [ invalid_feature ]

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ nil, {}, { "type" => "LineString", "coordinates" => [ 0, 0 ] } ].each do |invalid_geometry|
    it "rejects invalid geometry #{invalid_geometry.inspect}" do
      payload["features"][0]["geometry"] = invalid_geometry

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ nil, [], [ 0 ], [ 0, 0, 0 ], [ "0", 0 ], [ nil, 0 ], [ 181, 0 ], [ 0, 91 ], [ -181, 0 ], [ 0, -91 ] ].each do |invalid_coordinates|
    it "rejects invalid coordinates #{invalid_coordinates.inspect}" do
      payload["features"][0]["geometry"]["coordinates"] = invalid_coordinates

      expect { lookup }.to raise_error(described_class::InvalidResponseError)
    end
  end

  [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout ].each do |timeout|
    it "translates #{timeout} into a client timeout without retrying" do
      stub_request(:get, endpoint).with(query:).to_raise(timeout)

      expect { lookup }.to raise_error(described_class::TimeoutError)
      expect(provider_request).to have_been_requested.once
    end
  end

  [ SocketError, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError ].each do |network_error|
    it "translates #{network_error} into an unavailable error" do
      stub_request(:get, endpoint).with(query:).to_raise(network_error)

      expect { lookup }.to raise_error(described_class::UnavailableError)
    end
  end

  context "when the provider is rate limited" do
    let(:status) { 429 }
    let(:body) { "Too many requests" }

    it "raises a rate limit error without parsing the response or retrying" do
      expect { lookup }.to raise_error(described_class::RateLimitError)
      expect(provider_request).to have_been_requested.once
    end
  end

  [ 301, 400, 401, 402, 403, 500, 502, 503 ].each do |http_status|
    context "when the provider returns HTTP #{http_status}" do
      let(:status) { http_status }
      let(:body) { "Upstream error" }

      it "raises an unavailable error without following redirects or parsing the error body" do
        expect { lookup }.to raise_error(described_class::UnavailableError)
        expect(provider_request).to have_been_requested.once
      end
    end
  end
end
