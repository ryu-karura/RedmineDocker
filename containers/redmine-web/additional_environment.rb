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
#   passenger  Use :inline — jobs (mail notifications, project deletion) run
#              synchronously in the request instead of being queued. This is
#              the setting the redmine.jp Redmine 7 Docker + PostgreSQL guide
#              recommends for continuous use, over Redmine's default
#              AsyncAdapter, which keeps jobs in memory (lost on container
#              restart) and triggers the "default queue adapter" warning on
#              Administration > Information.
#              redmine_solid_queue cannot be used here: its supervisor only
#              auto-starts inside Puma, so under mod_passenger nothing would run
#              `plugins/redmine_solid_queue/bin/jobs` and jobs would sit in the
#              solid_queue tables forever. The plugin's Gemfile only sets
#              :solid_queue when the adapter is still unset ("respect
#              administrator's setting"), so setting it here is enough; the
#              plugin stays installed and its tables stay migrated, which keeps
#              a later switch to puma a restart, not a rebuild.
#
# REDMINE_WEB_SERVER reaches the Passenger-spawned app because the entrypoint
# execs Apache with the container env, and mod_passenger passes Apache's env on.
if ENV['REDMINE_WEB_SERVER'] == 'passenger'
  config.active_job.queue_adapter = :inline
end
