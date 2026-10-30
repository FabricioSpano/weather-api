abort("Refusing to run specs in production") if ENV["RAILS_ENV"] == "production"
# The development container exports RAILS_ENV; specs must still boot test.
ENV["RAILS_ENV"] = "test"
require_relative "spec_helper"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.file_fixture_path = Rails.root.join("spec/fixtures")
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
