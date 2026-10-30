class ForecastsController < ApplicationController
  before_action { response.set_header("Cache-Control", "no-store") }

  rescue_from Locations::Client::InvalidAddressError do |error|
    render_error(error, code: "invalid_address", status: 422)
  end

  rescue_from Locations::Client::NotFoundError do |error|
    render_error(error, code: "address_not_found", status: 422)
  end

  rescue_from Locations::Client::AmbiguousAddressError do |error|
    render_error(error, code: "ambiguous_address", status: 422, candidates: error.candidates)
  end

  rescue_from Weather::Client::InvalidCoordinatesError do |error|
    render_error(error, code: "invalid_coordinates", status: 422)
  end

  rescue_from Locations::Client::InvalidResponseError, Weather::Client::InvalidResponseError do |error|
    render_error(error, code: "invalid_response", status: 502)
  end

  rescue_from Locations::Client::TimeoutError, Weather::Client::TimeoutError do |error|
    render_error(error, code: "upstream_timeout", status: 504)
  end

  rescue_from Locations::Client::RateLimitError, Weather::Client::RateLimitError do |error|
    render_error(error, code: "upstream_rate_limited", status: 503)
  end

  rescue_from Locations::Client::UnavailableError, Weather::Client::UnavailableError do |error|
    render_error(error, code: "upstream_unavailable", status: 503)
  end

  def show
    result = Forecasts::Fetch.new.call(address: params[:address], zipcode: params[:zipcode], country: params[:country])
    render json: result.to_h
  end

  private

  def render_error(error, code:, status:, candidates: nil)
    details = { code:, message: error.message }
    details[:candidates] = candidates if candidates.present?
    render json: { error: details }, status:
  end
end
