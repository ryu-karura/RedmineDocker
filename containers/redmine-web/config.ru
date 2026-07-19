# containers/redmine-web/config.ru
#
# 公式 redmine:6.1.3 イメージの config.ru（単純な `run Rails.application`）を
# 置き換え、Puma 自身が RAILS_RELATIVE_URL_ROOT（/redmine）配下で
# アプリを配信できるようにします。
#
# httpd-redmine.conf は /redmine -> http://127.0.0.1:3000/redmine を
# プレフィックス未除去でプロキシします
# （ProxyPass /redmine http://127.0.0.1:3000/redmine）。
# そのため Apache 経由でもコンテナ healthcheck 直アクセスでも、
# Puma 側がこのプレフィックスを認識する必要があります。
# Rails の config.relative_url_root
# （RAILS_RELATIVE_URL_ROOT 由来）は URL 生成だけに作用し、
# リクエストディスパッチには効かないため、ここで明示 map します。

require_relative "config/environment"

relative_url_root = ENV["RAILS_RELATIVE_URL_ROOT"].to_s

if relative_url_root.empty?
  run Rails.application
else
  map relative_url_root do
    run Rails.application
  end
end
