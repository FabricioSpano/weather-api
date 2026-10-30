require "simplecov"

SimpleCov.start "rails" do
  enable_coverage :branch
  cover "{app,lib}/**/*.rb"
  group "Services", "app/services"
  merging false

  if ENV["CI"] == "true"
    coverage :line, minimum: 95
    coverage :branch, minimum: 90
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
