Oscurrency::Application.configure do
  # Settings specified here will take precedence over those in config/application.rb
  # XXX uncomment this for memcache
  #require 'active_support/cache/dalli_store23'
  #
  # In the development environment your application's code is reloaded on
  # every request.  This slows down response time but is perfect for development
  # since you don't have to restart the webserver when you make code changes.
  config.cache_classes = false

  # Show full error reports and disable caching
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  # XXX uncomment this for memcache
  #config.action_controller.perform_caching             = true
  #config.cache_store = :dalli_store

  # Don't care if the mailer can't send
  config.action_mailer.raise_delivery_errors = true

  # Print deprecation notices to the Rails logger
  config.active_support.deprecation = :log

  # Only use best-standards-support built into browsers
  config.action_dispatch.best_standards_support = :builtin

  # Do not compress assets
  # XXX config.assets.compress = false
  config.serve_static_assets = true
  config.assets.compress = false
  config.assets.compile = true
  config.assets.debug = true

  config.colorize_logging = true

  Rails.application.routes.default_url_options[:host] = 'localhost:3000'

  config.action_mailer.delivery_method = :letter_opener
  config.eager_load = false
end
