# containers/redmine-web/additional_environment.rb
#
# Installed as ${REDMINE_HOME}/config/additional_environment.rb by
# Containerfile.v5 / .v6 / .v7. Redmine's config/application.rb instance_evals
# this file inside RedmineApp::Application, so `config` is available here.
#
# Active Job queue adapter per app server (REDMINE_WEB_SERVER):
#
#   puma       Leave the adapter unset. On series 6/7, redmine_solid_queue then
#              sets :solid_queue and starts its supervisor as a Puma plugin
#              (series 5 ships no redmine_solid_queue, so Rails' :async applies).
#
#   passenger  Pin Redmine's standard adapter, :async (the Rails default Redmine
#              7.0.1 itself uses — its Gemfile has no solid_queue). The plugin's
#              supervisor only auto-starts inside Puma; under mod_passenger
#              nothing would run `plugins/redmine_solid_queue/bin/jobs`, so jobs
#              (mail notifications) would sit in the solid_queue tables forever.
#              redmine_solid_queue's Gemfile only sets :solid_queue when the
#              adapter is still unset ("respect administrator's setting"), so
#              setting it here is enough; the plugin stays installed and its
#              tables stay migrated, which keeps a later switch to puma a
#              restart, not a rebuild.
#
# REDMINE_WEB_SERVER reaches the Passenger-spawned app because the entrypoint
# execs Apache with the container env, and mod_passenger passes Apache's env on.
if ENV['REDMINE_WEB_SERVER'] == 'passenger'
  config.active_job.queue_adapter = :async
end
