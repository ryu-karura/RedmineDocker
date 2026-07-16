# containers/redmine-web/config.ru
#
# Replaces the official redmine:6.1.3 image's config.ru (which is a plain
# `run Rails.application`, with no notion of a sub-URI) so Puma itself
# serves the app under RAILS_RELATIVE_URL_ROOT (/redmine).
#
# httpd-redmine.conf proxies /redmine -> http://127.0.0.1:3000/redmine
# WITHOUT stripping the prefix (ProxyPass /redmine http://127.0.0.1:3000/redmine),
# so Puma must recognize that prefix itself, whether reached through Apache or
# directly (as the container healthcheck does). config.relative_url_root
# (defaulted from RAILS_RELATIVE_URL_ROOT by Rails) only affects URL
# generation, not request dispatch, so the app must be explicitly mapped here.

require_relative "config/environment"

relative_url_root = ENV["RAILS_RELATIVE_URL_ROOT"].to_s

if relative_url_root.empty?
  run Rails.application
else
  map relative_url_root do
    run Rails.application
  end
end
