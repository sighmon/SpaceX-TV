#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "spacex_x_card_processor"

TOKEN = ENV["X_BEARER_TOKEN"]
OUTPUT_PATH = File.expand_path(
  ENV.fetch("SPACEX_TV_X_CACHE_PATH", "~/www.sighmon.com/spacex-tv/x-cache.json")
)

COMMON_POST_QUERY = [
  "tweet.fields=created_at,entities,attachments,referenced_tweets",
  "expansions=attachments.media_keys,referenced_tweets.id,referenced_tweets.id.attachments.media_keys",
  "media.fields=type,variants,preview_image_url,url,width,height,media_key,alt_text"
].join("&")

STARSHIP_PLAYLIST_URL = "https://content.spacex.com/api/spacex-website/media-playlist/starship"
STARSHIP_FLIGHT_TESTS_PLAYLIST_URL = "https://content.spacex.com/api/spacex-website/media-playlist/starship-flight-tests"
STARSHIP_TALKS_PLAYLIST_URL = "https://content.spacex.com/api/spacex-website/media-playlist/starship-talks"
LAUNCH_TILES_URL = "https://content.spacex.com/api/spacex-website/launches-page-tiles"
MISSIONS_BASE_URL = "https://content.spacex.com/api/spacex-website/missions/"

def get_json(url, bearer_token: nil)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/json"
  request["User-Agent"] = "SpaceXTV hosted cache updater"
  request["Authorization"] = "Bearer #{bearer_token}" if bearer_token

  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      raise "HTTP #{response.code} for #{url}: #{response.body[0, 500]}"
    end

    JSON.parse(response.body)
  end
end

def log(message)
  puts "[#{Time.now.utc.iso8601}] #{message}"
end

begin
  log "Starting SpaceX TV X cache update"
  raise "X_BEARER_TOKEN is not set" if TOKEN.nil? || TOKEN.empty?

  user = get_json(
    "https://api.x.com/2/users/by/username/spacex?user.fields=pinned_tweet_id",
    bearer_token: TOKEN
  )
  user_id = user.fetch("data").fetch("id")
  pinned_tweet_id = user.fetch("data")["pinned_tweet_id"]

  timeline = get_json(
    "https://api.x.com/2/users/#{user_id}/tweets?max_results=25&#{COMMON_POST_QUERY}&exclude=replies",
    bearer_token: TOKEN
  )

  pinned = if pinned_tweet_id && !pinned_tweet_id.empty?
    get_json(
      "https://api.x.com/2/tweets?ids=#{pinned_tweet_id}&#{COMMON_POST_QUERY}",
      bearer_token: TOKEN
    )
  end

  starship_playlist = get_json(STARSHIP_PLAYLIST_URL)
  starship_flight_tests_playlist = get_json(STARSHIP_FLIGHT_TESTS_PLAYLIST_URL)
  starship_talks_playlist = begin
    get_json(STARSHIP_TALKS_PLAYLIST_URL)
  rescue StandardError => error
    log "Could not cache Starship talks playlist: #{error.class}: #{error.message}"
    nil
  end
  launch_tiles = get_json(LAUNCH_TILES_URL)
  starship_mission_links = Array(launch_tiles)
    .select { |tile| tile["vehicle"] == "Starship" && !tile["link"].to_s.empty? }
    .map { |tile| tile.fetch("link") }
    .uniq
  starship_missions = starship_mission_links.filter_map do |link|
    mission = get_json("#{MISSIONS_BASE_URL}#{URI.encode_www_form_component(link)}")
    [link, mission]
  rescue StandardError => error
    log "Could not cache Starship mission #{link}: #{error.class}: #{error.message}"
    nil
  end.to_h
  log "Cached #{Array(starship_playlist["media"]).count} Starship films"
  log "Cached #{Array(starship_talks_playlist&.fetch("media", nil)).count} Starship talks"
  log "Cached #{Array(starship_flight_tests_playlist["media"]).count} Starship flight test films"
  log "Cached #{starship_missions.count} Starship mission records"

  existing_cache = if File.file?(OUTPUT_PATH)
    begin
      JSON.parse(File.read(OUTPUT_PATH))
    rescue JSON::ParserError => error
      log "Could not reuse existing processed cards: #{error.message}"
      nil
    end
  end
  processed_cards = SpaceXXCardProcessor.new(
    existing_cache: existing_cache,
    logger: ->(message) { log message }
  ).process(pinned, timeline)
  log "Processed #{processed_cards.fetch("entries").count} broadcast/gallery cards"

  payload = {
    generated_at: Time.now.utc.iso8601,
    source: "x-api-and-spacex-cms-cache-v4",
    user: user,
    pinned: pinned,
    timeline: timeline,
    processed_cards: processed_cards,
    starship_playlist: starship_playlist,
    starship_flight_tests_playlist: starship_flight_tests_playlist,
    starship_talks_playlist: starship_talks_playlist,
    starship_launch_tiles: launch_tiles,
    starship_missions: starship_missions
  }

  FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
  temporary_path = "#{OUTPUT_PATH}.tmp"
  File.write(temporary_path, JSON.pretty_generate(payload))
  File.rename(temporary_path, OUTPUT_PATH)

  log "Wrote #{OUTPUT_PATH}"
rescue StandardError => error
  log "Failed SpaceX TV X cache update: #{error.class}: #{error.message}"
  raise
end
