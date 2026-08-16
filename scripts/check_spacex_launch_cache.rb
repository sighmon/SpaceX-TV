#!/usr/bin/env ruby

require "json"
require "net/http"
require "rbconfig"
require "time"
require "uri"

UPDATE_SCRIPT = File.expand_path(
  ENV.fetch("SPACEX_TV_X_UPDATE_SCRIPT", File.join(__dir__, "update_spacex_x_cache.rb"))
)
RUBY = ENV.fetch("SPACEX_TV_RUBY", RbConfig.ruby)
THRESHOLD_SECONDS = Integer(ENV.fetch("SPACEX_TV_LAUNCH_CHECK_THRESHOLD_SECONDS", "600"))
TILES_URL = ENV.fetch(
  "SPACEX_TV_LAUNCH_TILES_URL",
  "https://content.spacex.com/api/spacex-website/launches-page-tiles/upcoming"
)
TIMINGS_URL = ENV.fetch(
  "SPACEX_TV_LAUNCH_TIMINGS_URL",
  "https://sxcontent9668.azureedge.us/cms-assets/future_missions.json"
)

def log(message)
  puts "[#{Time.now.utc.iso8601}] #{message}"
end

def get_json(url)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/json"
  request["User-Agent"] = "SpaceXTV launch cache checker"

  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      raise "SpaceX HTTP #{response.code} for #{url}: #{response.body[0, 500]}"
    end

    JSON.parse(response.body)
  end
end

def timestamp_time(value)
  seconds = value["Seconds"] || value["seconds"]
  return unless seconds

  Time.at(seconds.to_f).utc
end

def launch_time(timing)
  if timing["TZeroPaused"] != true && timing["TZeroLaunchDate"]
    return timestamp_time(timing["TZeroLaunchDate"])
  end

  if timing.dig("PrimaryLaunchWindow", "Open")
    return timestamp_time(timing.dig("PrimaryLaunchWindow", "Open"))
  end

  timestamp_time(timing["PrimaryLaunchDate"])
end

def next_launch(tiles, timings, now)
  launches = tiles.filter_map do |tile|
    timing = timings[tile["correlationId"]]
    time = timing && launch_time(timing)
    next unless time

    {
      title: tile["shortTitle"].to_s.empty? ? tile["title"] : tile["shortTitle"],
      link: tile["link"],
      time: time
    }
  end

  launches.select { |launch| launch[:time] >= now }.min_by { |launch| launch[:time] }
end

def run_update_script
  raise "Update script not found: #{UPDATE_SCRIPT}" unless File.file?(UPDATE_SCRIPT)

  log "Running X cache update script: #{UPDATE_SCRIPT}"
  success = system(RUBY, UPDATE_SCRIPT)
  raise "X cache update script failed with status #{$?.exitstatus}" unless success
end

begin
  log "Starting SpaceX launch cache check"

  now = Time.now.utc
  tiles = get_json(TILES_URL)
  timings = get_json(TIMINGS_URL)
  launch = next_launch(tiles, timings, now)

  unless launch
    log "No upcoming SpaceX launch found"
    exit
  end

  seconds_until_launch = (launch[:time] - now).round
  log "Next launch: #{launch[:title]} at #{launch[:time].iso8601} (#{seconds_until_launch}s from now)"

  if seconds_until_launch.negative?
    log "Launch time has already passed; skipping cache update"
    exit
  end

  if seconds_until_launch > THRESHOLD_SECONDS
    log "Launch is outside #{THRESHOLD_SECONDS}s check window; skipping cache update"
    exit
  end

  log "Launch is inside #{THRESHOLD_SECONDS}s window"
  run_update_script
rescue StandardError => error
  log "Failed SpaceX launch cache check: #{error.class}: #{error.message}"
  raise
end
