# containers/redmine-prod/puma.rb
#
# Puma configuration for Redmine 6.1.3 — Production Environment
#
# Puma runs in cluster mode (pre-fork) with 2 workers and up to 5 threads each.
# It listens on a Unix domain socket under tmp/ so Apache can proxy to it.
# The redmine_solid_queue plugin auto-starts Solid Queue as a Puma plugin.

# ── Deployment environment ────────────────────────────────────────────────────
environment ENV.fetch("RAILS_ENV", "production")

# ── Binding ───────────────────────────────────────────────────────────────────
# Unix socket for Apache mod_proxy communication.
# The socket path must match the ProxyPass directive in apache/redmine.conf.
socket_path = File.expand_path("tmp/puma.sock", __dir__ + "/..")
bind "unix://#{socket_path}"

# ── Process model ─────────────────────────────────────────────────────────────
# Workers: 2 forked processes. Adjust based on available RAM (each worker ~250MB).
workers 2

# Threads per worker: min 1, max 5.
threads 1, 5

# ── PID and state files ───────────────────────────────────────────────────────
pidfile File.expand_path("tmp/pids/puma.pid", __dir__ + "/..")
state_path File.expand_path("tmp/pids/puma.state", __dir__ + "/..")

# ── Logging ───────────────────────────────────────────────────────────────────
# stdout_redirect sends Puma's access and error logs to files on the bind-mounted
# log volume so they are accessible on the host for inspection and logrotate.
stdout_redirect \
    File.expand_path("log/puma.log", __dir__ + "/.."),
    File.expand_path("log/puma_error.log", __dir__ + "/.."),
    true   # append mode

# ── Worker lifecycle hooks ────────────────────────────────────────────────────
before_fork do
    # Ensure the database connection pool is closed before forking to avoid
    # connection sharing between master and workers.
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
end

on_worker_boot do
    # Re-establish the database connection after forking.
    ActiveSupport.on_load(:active_record) do
        ActiveRecord::Base.establish_connection
    end
end

# ── Preload application ───────────────────────────────────────────────────────
# Preloading loads the Rails app in the master process before forking workers.
# This reduces startup time and memory footprint (Copy-on-Write).
preload_app!

# ── Socket permissions ────────────────────────────────────────────────────────
# Set socket permissions so Apache (running as root inside container) can write.
# The socket is owned by redmine_adm:redmine with mode 0660.
# Apache is a member of the 'redmine' group inside the container.
socket_umask 0007   # resulting mode: 0770

# ── Graceful restart ──────────────────────────────────────────────────────────
# To trigger a graceful restart without stopping the server:
#   touch /opt/redmine/app/tmp/restart.txt
# Puma's phased restart drains each worker before replacing it.
plugin :tmp_restart
