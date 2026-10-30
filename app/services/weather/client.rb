require "json"
require "open_meteo"

module Weather
  class Client
    class Error < StandardError; end
    class InvalidCoordinatesError < Error; end
    class InvalidResponseError < Error; end
    class TimeoutError < Error; end
    class RateLimitError < Error; end
    class UnavailableError < Error; end

    Forecast = Data.define(:current_temperature, :temperature_unit, :current_time, :timezone, :utc_offset_seconds, :daily)

    DEFAULT_HOST = "api.open-meteo.com".freeze
    FORECAST_DAYS = 7
    TEMPERATURE_UNIT = "°C".freeze

    def initialize(host: ENV.fetch("WEATHER_HOST", DEFAULT_HOST))
      unless hostname?(host)
        raise ArgumentError, "WEATHER_HOST must be a hostname without a scheme or path"
      end

      config = OpenMeteo::Client::Config.new(host:, logger: Rails.logger, timeouts: Connection::TIMEOUTS)
      @client = OpenMeteo::Client.new(config:, agent: Connection.new(config:))
    end

    def call(latitude:, longitude:)
      unless coordinate?(latitude, -90..90) && coordinate?(longitude, -180..180)
        raise InvalidCoordinatesError, "Provide finite numeric latitude and longitude within their valid ranges"
      end

      response = @client.get(:forecast, query_params: {
        latitude: latitude.to_f, longitude: longitude.to_f,
        current: "temperature_2m", daily: "temperature_2m_min,temperature_2m_max",
        temperature_unit: "celsius", forecast_days: FORECAST_DAYS,
        timezone: "auto", timeformat: "unixtime"
      })

      normalize(parse(response))
    rescue OpenMeteo::Client::Timeout
      raise TimeoutError, "Weather provider timed out"
    rescue OpenMeteo::Client::ConnectionFailed => error
      raise TimeoutError, "Weather provider timed out" if timeout_cause?(error)

      raise UnavailableError, "Weather provider is unavailable"
    rescue Faraday::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError,
           Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      raise UnavailableError, "Weather provider is unavailable"
    end

    private

    def hostname?(host)
      host.is_a?(String) && !host.empty? && URI("https://#{host}").host == host
    rescue URI::InvalidURIError
      false
    end

    def parse(response)
      raise RateLimitError, "Weather provider rate limit exceeded" if response.status == 429
      unless response.status == 200
        raise UnavailableError, "Weather provider returned HTTP #{response.status}"
      end

      unless response.body.is_a?(String)
        raise InvalidResponseError, "Weather provider returned an empty response"
      end

      payload = JSON.parse(response.body)
      unless payload.is_a?(Hash) && !payload["error"]
        raise InvalidResponseError, "Weather provider returned an invalid forecast"
      end

      payload
    rescue JSON::ParserError
      raise InvalidResponseError, "Weather provider returned invalid JSON"
    end

    def normalize(payload)
      current = object(payload, "current")
      validate_units(object(payload, "current_units"), %w[temperature_2m])
      validate_units(object(payload, "daily_units"), %w[temperature_2m_min temperature_2m_max])
      timezone = payload["timezone"]
      unless timezone.is_a?(String) && Time.find_zone(timezone)
        raise InvalidResponseError, "Weather provider returned an invalid timezone"
      end

      offset = payload["utc_offset_seconds"]
      unless offset.is_a?(Integer) && offset.abs < 86_400
        raise InvalidResponseError, "Weather provider returned an invalid UTC offset"
      end

      Forecast.new(
        current_temperature: temperature(current["temperature_2m"]),
        temperature_unit: TEMPERATURE_UNIT,
        current_time: timestamp(current["time"]).utc.iso8601.freeze,
        timezone: timezone.freeze, utc_offset_seconds: offset,
        daily: daily_forecast(object(payload, "daily"), offset)
      )
    end

    def object(payload, key)
      value = payload[key]
      unless value.is_a?(Hash)
        raise InvalidResponseError, "Weather provider omitted required #{key} data"
      end

      value
    end

    def validate_units(units, variables)
      unless units["time"] == "unixtime" && variables.all? { |variable| units[variable] == TEMPERATURE_UNIT }
        raise InvalidResponseError, "Weather provider returned unexpected measurement units"
      end
    end

    def daily_forecast(daily, offset)
      times, minimums, maximums = daily.values_at("time", "temperature_2m_min", "temperature_2m_max")
      unless [ times, minimums, maximums ].all? { |values| values.is_a?(Array) && values.length == FORECAST_DAYS }
        raise InvalidResponseError, "Weather provider returned an incomplete daily forecast"
      end

      dates = times.map { |value| timestamp(value).getlocal(offset).to_date }
      unless dates.each_cons(2).all? { |previous, following| following == previous + 1 }
        raise InvalidResponseError, "Weather provider returned inconsistent forecast dates"
      end

      dates.each_with_index.map do |date, index|
        minimum = temperature(minimums[index])
        maximum = temperature(maximums[index])
        raise InvalidResponseError, "Weather provider returned an inverted temperature range" if minimum > maximum

        { date: date.iso8601.freeze, temperature_min: minimum, temperature_max: maximum }.freeze
      end.freeze
    end

    def temperature(value)
      unless value.is_a?(Numeric) && value.real? && value.finite?
        raise InvalidResponseError, "Weather provider returned an invalid temperature"
      end

      value.to_f
    end

    def timestamp(value)
      unless value.is_a?(Integer) && value.positive?
        raise InvalidResponseError, "Weather provider returned an invalid timestamp"
      end

      Time.at(value)
    rescue RangeError
      raise InvalidResponseError, "Weather provider returned an invalid timestamp"
    end

    def coordinate?(value, range)
      value.is_a?(Numeric) && value.real? && value.finite? && range.cover?(value)
    end

    def timeout_cause?(error)
      while error
        return true if error.is_a?(::Timeout::Error)

        error = error.cause
      end
      false
    end
  end
end
