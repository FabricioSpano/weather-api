require "open_meteo"

module Weather
  class Connection < OpenMeteo::FaradayConnection
    TIMEOUTS = { open_timeout: 2, timeout: 3, write_timeout: 3 }.freeze
    USER_AGENT = "WeatherApi/1.0 (https://github.com/FabricioSpano/weather-api)".freeze

    def connect
      Faraday.new(
        request: config.timeouts,
        headers: { "Accept" => "application/json", "User-Agent" => USER_AGENT }
      ) do |connection|
        connection.adapter :net_http do |http|
          http.max_retries = 0
        end
      end
    end
  end
end
