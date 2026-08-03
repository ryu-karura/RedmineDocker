# containers/redmine-web/config.ru
#
# 公式 redmine:6.1.3 イメージの config.ru（単純な `run Rails.application`）を
# 置き換え、Puma 自身が RAILS_RELATIVE_URL_ROOT（/redmine）配下で
# アプリを配信できるようにします。
#
# REDMINE_WEB_SERVER=puma のとき:
#   httpd-redmine.conf は /redmine -> http://127.0.0.1:3000/redmine を
#   プレフィックス未除去でプロキシします
#   （ProxyPass /redmine http://127.0.0.1:3000/redmine）。
#   そのため Apache 経由でもコンテナ healthcheck 直アクセスでも、
#   Puma 側がこのプレフィックスを認識する必要があります。
#   Rails の config.relative_url_root
#   （RAILS_RELATIVE_URL_ROOT 由来）は URL 生成だけに作用し、
#   リクエストディスパッチには効かないため、ここで明示 map します。
#
# REDMINE_WEB_SERVER=passenger のとき:
#   mod_passenger は PassengerBaseURI により SCRIPT_NAME を /redmine に設定し、
#   PATH_INFO からはプレフィックスを除去した状態でアプリを呼び出します。
#   Rack::URLMap（= `map`）は PATH_INFO を見てマッチさせるため、ここで map すると
#   "/login" が "/redmine" にマッチせず全リクエストが 404 になります。
#   Passenger 配下では map せず、素の Rails.application を run します。
#   （Passenger は config.ru 評価前に phusion_passenger を require 済みなので、
#     PhusionPassenger 定数の有無で判定できます。Passenger 公式のイディオムです。）

require_relative "config/environment"

relative_url_root = ENV["RAILS_RELATIVE_URL_ROOT"].to_s

if defined?(PhusionPassenger) || relative_url_root.empty?
  run Rails.application
else
  map relative_url_root do
    run Rails.application
  end
end
