require "cgi"
require "json"
require "net/http"
require "time"
require "uri"

class SpaceXXCardProcessor
  CACHE_VERSION = 4
  REPLAY_TTL = 7 * 24 * 60 * 60
  LIVE_TTL = 15 * 60
  NEGATIVE_TTL = 25 * 60 * 60

  TWEET_RESULT_FEATURES = {
    creator_subscriptions_tweet_preview_api_enabled: true,
    premium_content_api_read_enabled: true,
    communities_web_enable_tweet_community_results_fetch: true,
    c9s_tweet_anatomy_moderator_badge_enabled: true,
    responsive_web_grok_analyze_button_fetch_trends_enabled: true,
    responsive_web_grok_analyze_post_followups_enabled: true,
    rweb_cashtags_composer_attachment_enabled: true,
    responsive_web_jetfuel_frame: true,
    responsive_web_grok_share_attachment_enabled: true,
    responsive_web_grok_annotations_enabled: true,
    articles_preview_enabled: true,
    responsive_web_edit_tweet_api_enabled: true,
    graphql_is_translatable_rweb_tweet_is_translatable_enabled: true,
    view_counts_everywhere_api_enabled: true,
    longform_notetweets_consumption_enabled: true,
    responsive_web_twitter_article_tweet_consumption_enabled: true,
    tweet_awards_web_tipping_enabled: false,
    responsive_web_grok_show_grok_translated_post: true,
    responsive_web_grok_analysis_button_from_backend: true,
    standardized_nudges_misinfo: true,
    tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled: true,
    longform_notetweets_rich_text_read_enabled: true,
    longform_notetweets_inline_media_enabled: true,
    responsive_web_grok_image_annotation_enabled: true,
    responsive_web_grok_imagine_annotation_enabled: true,
    responsive_web_grok_community_note_auto_translation_is_enabled: true,
    responsive_web_enhance_cards_enabled: true
  }.freeze

  TWEET_RESULT_FIELD_TOGGLES = {
    withArticleRichContentState: true,
    withArticlePlainText: true,
    withGrokAnalyze: true,
    withDisallowedReplyControls: true
  }.freeze

  def initialize(existing_cache: nil, logger: nil, now: Time.now.utc)
    processed_cache = existing_cache&.fetch("processed_cards", nil)
    @existing_entries = processed_cache&.fetch("version", nil) == CACHE_VERSION ? processed_cache.fetch("entries", {}) : {}
    @logger = logger || ->(_message) {}
    @now = now
    @web_configuration = nil
  end

  def process(*responses)
    entries = {}
    seen = {}

    responses.compact.each do |response|
      media_by_key = Array(response.dig("includes", "media")).to_h { |media| [media["media_key"], media] }
      posts_by_id = Array(response.dig("includes", "tweets")).to_h { |post| [post["id"], post] }

      Array(response["data"]).each do |post|
        next if seen[post["id"]]

        seen[post["id"]] = true
        entry = process_post(post, media_by_key: media_by_key, posts_by_id: posts_by_id)
        entries["post:#{post.fetch("id")}"] = entry if entry
      end
    end

    { "version" => CACHE_VERSION, "entries" => entries }
  end

  private

  def process_post(post, media_by_key:, posts_by_id:)
    referenced_content = referenced_content_for(post, posts_by_id)
    referenced_post = referenced_content[:post]
    own_media = media_for(post, media_by_key)
    referenced_media = referenced_post ? media_for(referenced_post, media_by_key) : []
    selected_media = own_media.empty? ? referenced_media : own_media
    linked_broadcast_url = broadcast_url(post) || broadcast_url(referenced_post)
    fingerprint = content_fingerprint(
      post,
      media: selected_media,
      referenced_content: referenced_content,
      referenced_media: referenced_media,
      linked_broadcast_url: linked_broadcast_url
    )
    key = "post:#{post.fetch("id")}"

    if reusable_entry?(entry = @existing_entries[key], fingerprint)
      @logger.call("Reused processed card #{post.fetch("id")}")
      return entry
    end

    thumbnail_url = selected_media.filter_map { |media| media["preview_image_url"] || media["url"] }.first ||
      entity_thumbnail_url(post) || entity_thumbnail_url(referenced_post)
    video_media = selected_media.select { |media| video_media?(media) }
    photos = gallery_images(selected_media)
    first_variant = video_media.empty? ? nil : best_variant([video_media.first])

    # Multi-video / mixed posts still publish content_kind "video" so older app builds
    # can decode processed_cards (they only know video|gallery). Newer app builds open a
    # collection picker from the timeline media attachments themselves.
    if first_variant
      return card_entry(
        fingerprint: fingerprint,
        stream_url: first_variant["url"],
        thumbnail_url: thumbnail_url || photos.first&.dig("url"),
        content_kind: "video",
        ttl: REPLAY_TTL
      )
    end

    if linked_broadcast_url
      resolved = resolve_broadcast(linked_broadcast_url)
      stream_url = resolved[:stream_url]
      # Not-started livestreams are still useful cards (UPCOMING). Re-check soon so
      # the stream URL appears once X starts the HLS endpoint.
      ttl = if resolved[:is_live] || stream_url.nil?
        LIVE_TTL
      else
        REPLAY_TTL
      end
      return card_entry(
        fingerprint: fingerprint,
        stream_url: stream_url,
        thumbnail_url: thumbnail_url || resolved[:thumbnail_url],
        is_live: resolved[:is_live],
        content_kind: "video",
        has_usable_content: true,
        ttl: ttl
      )
    end

    unless photos.empty?
      return card_entry(
        fingerprint: fingerprint,
        stream_url: nil,
        thumbnail_url: thumbnail_url || photos.first["url"],
        content_kind: "gallery"
      )
    end

    stream_url, page_thumbnail = stream_from_page("https://x.com/spacex/status/#{post.fetch("id")}")
    if stream_url
      card_entry(
        fingerprint: fingerprint,
        stream_url: stream_url,
        thumbnail_url: thumbnail_url || page_thumbnail,
        content_kind: "video",
        ttl: REPLAY_TTL
      )
    else
      card_entry(
        fingerprint: fingerprint,
        stream_url: nil,
        thumbnail_url: nil,
        content_kind: "video",
        has_usable_content: false,
        ttl: NEGATIVE_TTL
      )
    end
  rescue StandardError => error
    @logger.call("Could not process card #{post["id"]}: #{error.class}: #{error.message}")
    nil
  end

  def reusable_entry?(entry, fingerprint)
    return false unless entry && entry["fingerprint"] == fingerprint
    return true unless entry["expiresAt"]

    Time.parse(entry["expiresAt"]) > @now
  rescue ArgumentError
    false
  end

  def card_entry(fingerprint:, stream_url:, thumbnail_url:, content_kind:, is_live: nil, has_usable_content: true, ttl: nil)
    {
      "fingerprint" => fingerprint,
      "lastChecked" => @now.iso8601,
      "expiresAt" => ttl ? (@now + ttl).iso8601 : nil,
      "streamURL" => stream_url,
      "thumbnailURL" => thumbnail_url,
      "isLive" => is_live,
      "contentKind" => content_kind,
      "hasUsableContent" => has_usable_content
    }
  end

  def referenced_content_for(post, posts_by_id)
    reference = Array(post["referenced_tweets"]).find { |item| ["quoted", "retweeted"].include?(item["type"]) }
    {
      reference: reference,
      post: reference && posts_by_id[reference["id"]]
    }
  end

  def media_for(post, media_by_key)
    Array(post.dig("attachments", "media_keys")).filter_map { |key| media_by_key[key] }
  end

  def video_media?(media)
    %w[video animated_gif].include?(media["type"])
  end

  def best_variant(media)
    variants = media.flat_map { |item| Array(item["variants"]) }
      .select { |variant| variant["url"].to_s.start_with?("http") }
    mp4 = variants.select do |variant|
      variant["content_type"] == "video/mp4" || URI(variant["url"]).path.end_with?(".mp4")
    rescue URI::InvalidURIError
      false
    end
    return mp4.max_by { |variant| variant["bit_rate"].to_i } unless mp4.empty?

    variants.find do |variant|
      variant["content_type"] == "application/x-mpegURL" || URI(variant["url"]).path.end_with?(".m3u8")
    rescue URI::InvalidURIError
      false
    end
  end

  def gallery_images(media)
    media.filter_map do |item|
      next unless item["type"] == "photo" && item["url"]

      {
        "url" => full_size_photo_url(item["url"]),
        "width" => item["width"],
        "height" => item["height"],
        "altText" => item["alt_text"]
      }
    end
  end

  def full_size_photo_url(value)
    uri = URI(value)
    return value unless uri.host&.downcase&.end_with?("twimg.com")

    params = URI.decode_www_form(uri.query.to_s).reject { |name, _| name == "name" }
    params << ["name", "orig"]
    uri.query = URI.encode_www_form(params)
    uri.to_s
  rescue URI::InvalidURIError
    value
  end

  def broadcast_url(post)
    return unless post

    Array(post.dig("entities", "urls")).filter_map do |url|
      value = url["unwound_url"] || url["expanded_url"] || url["url"]
      next unless value

      uri = URI(value)
      next unless uri.host&.downcase&.match?(%r{(^|\.)(x|twitter)\.com$})
      next unless uri.path.start_with?("/i/broadcasts/")

      value
    rescue URI::InvalidURIError
      nil
    end.first
  end

  def entity_thumbnail_url(post)
    return unless post

    Array(post.dig("entities", "urls"))
      .flat_map { |url| Array(url["images"]) }
      .select { |image| image["url"] }
      .max_by { |image| image["width"].to_i * image["height"].to_i }
      &.fetch("url", nil)
  end

  def content_fingerprint(post, media:, referenced_content:, referenced_media:, linked_broadcast_url:)
    parts = ["id:#{post.fetch("id")}"]
    text = post["text"].to_s.strip
    parts << "t:#{text}" unless text.empty?
    parts << "at:#{Time.parse(post["created_at"]).to_i}" if post["created_at"]
    parts << "lnk:#{linked_broadcast_url}" if linked_broadcast_url
    own = media.map { |item| media_fingerprint(item) }.sort
    parts << "m:#{own.join(",")}" unless own.empty?
    if (reference = referenced_content[:reference])
      parts << "r:#{reference["type"]}:#{reference["id"]}"
    end
    referenced = referenced_media.map { |item| media_fingerprint(item) }.sort
    parts << "rm:#{referenced.join(",")}" unless referenced.empty?
    parts.join("|")
  end

  def media_fingerprint(media)
    variants = Array(media["variants"]).map do |variant|
      "#{variant["url"]}:#{variant["content_type"]}:#{variant["bit_rate"]}"
    end.sort.join(",")
    [
      media["media_key"], media["type"], variants, media["preview_image_url"], media["url"],
      media["width"], media["height"], media["alt_text"]
    ].map { |value| value.nil? ? "" : value.to_s }.join(":")
  end

  def resolve_broadcast(value)
    broadcast_id = URI(value).path.split("/").last
    configuration = web_configuration
    guest_token = activate_guest(configuration.fetch(:bearer_token))

    begin
      broadcast = request_json(
        "https://api.x.com/1.1/broadcasts/show.json?#{URI.encode_www_form(ids: broadcast_id)}",
        bearer_token: configuration.fetch(:bearer_token),
        guest_token: guest_token
      ).fetch("broadcasts").fetch(broadcast_id)

      # X publishes the card (and scheduled start) before the HLS endpoint exists.
      if not_started_broadcast_state?(broadcast["state"])
        # page_thumbnail_for already soft-fails to nil on scrape errors.
        thumbnail = best_broadcast_thumbnail(broadcast) ||
          page_thumbnail_for("https://x.com/i/broadcasts/#{broadcast_id}")
        return {
          stream_url: nil,
          thumbnail_url: thumbnail,
          is_live: false
        }
      end

      media_key = broadcast.fetch("media_key")
      source = live_video_source(media_key, configuration.fetch(:bearer_token), guest_token)
      thumbnail_url = best_broadcast_thumbnail(broadcast) || source["thumbnail_url"] || source["image_url"]
      thumbnail_url ||= page_thumbnail_for("https://x.com/i/broadcasts/#{broadcast_id}")
      {
        stream_url: source["noRedirectPlaybackUrl"] || source["location"],
        thumbnail_url: thumbnail_url,
        is_live: broadcast["state"]&.downcase == "running"
      }
    rescue StandardError
      raise unless broadcast_id.match?(/\A\d+\z/)

      resolve_tweet_broadcast(broadcast_id, configuration, guest_token)
    end
  end

  def resolve_tweet_broadcast(tweet_id, configuration, guest_token)
    query_id = configuration[:query_id]
    raise "Could not find TweetResultByRestId query ID" unless query_id
    query = URI.encode_www_form(
      variables: JSON.generate(tweetId: tweet_id, withCommunity: false, includePromotedContent: false, withVoice: false),
      features: JSON.generate(TWEET_RESULT_FEATURES),
      fieldToggles: JSON.generate(TWEET_RESULT_FIELD_TOGGLES)
    )
    response = request_json(
      "https://x.com/i/api/graphql/#{query_id}/TweetResultByRestId?#{query}",
      bearer_token: configuration.fetch(:bearer_token),
      guest_token: guest_token
    )
    bindings = response.dig("data", "tweetResult", "result", "card", "legacy", "binding_values")
    values = Array(bindings).to_h { |binding| [binding["key"], binding["value"]] }
    state = values.dig("broadcast_state", "string_value")
    thumbnails = %w[
      broadcast_thumbnail_original broadcast_thumbnail_x_large broadcast_thumbnail
      broadcast_pre_live_slate_x_large
    ].filter_map { |key| values.dig(key, "image_value", "url") }

    # Check state before requiring media_key — pre-live cards may omit it.
    if not_started_broadcast_state?(state)
      return {
        stream_url: nil,
        thumbnail_url: thumbnails.first,
        is_live: false
      }
    end

    media_key = values.dig("broadcast_media_key", "string_value")
    raise "Tweet broadcast has no media key" unless media_key

    source = live_video_source(media_key, configuration.fetch(:bearer_token), guest_token)
    {
      stream_url: source["noRedirectPlaybackUrl"] || source["location"],
      thumbnail_url: thumbnails.first || source["thumbnail_url"] || source["image_url"],
      is_live: state&.downcase == "running"
    }
  end

  def not_started_broadcast_state?(state)
    %w[not_started pre_published].include?(state&.downcase)
  end

  def best_broadcast_thumbnail(broadcast)
    %w[
      image_url_original image_url_large image_url_medium image_url image_url_small
      thumbnail_url_large thumbnail_url_medium thumbnail_url thumbnail_url_small
      pre_live_slate_url
    ].filter_map { |key| broadcast[key] }.first
  end

  def live_video_source(media_key, bearer_token, guest_token)
    request_json(
      "https://api.x.com/1.1/live_video_stream/status/#{media_key}",
      bearer_token: bearer_token,
      guest_token: guest_token
    ).fetch("source")
  end

  def activate_guest(bearer_token)
    request_json(
      "https://api.x.com/1.1/guest/activate.json",
      method: :post,
      bearer_token: bearer_token
    ).fetch("guest_token")
  end

  def web_configuration
    return @web_configuration if @web_configuration

    home = request_text("https://x.com/")
    bearer_token = web_bearer_token(home)
    query_id = tweet_result_query_id(home)

    # X's logged-out SPA only links an entry module; guest-token and other
    # chunks are relative imports. Expand the module graph, then fetch in
    # priority order (guest-token first).
    candidates = web_script_urls(home)
    visited = {}
    max_fetches = 15

    while candidates.any? && visited.size < max_fetches && !(bearer_token && query_id)
      script_url = candidates.shift
      next if visited[script_url]

      visited[script_url] = true
      script = request_text(script_url)
      bearer_token ||= web_bearer_token(script)
      query_id ||= tweet_result_query_id(script)

      discovered = web_script_urls(script, base_url: script_url)
      next if discovered.empty?

      remaining = candidates
      candidates = prioritize_web_scripts((discovered + remaining).uniq)
      candidates.reject! { |url| visited[url] }
    end

    raise "Could not find X web bearer token" unless bearer_token

    @web_configuration = { bearer_token: bearer_token, query_id: query_id }
  end

  # Collect absolute CDN script URLs from HTML/JS, plus relative ES-module
  # imports when +base_url+ is the module that declared them.
  def web_script_urls(body, base_url: nil)
    urls = body.scan(
      %r{https://abs\.twimg\.com/(?:responsive-web/client-web|x-web/x-web)/[^"'<>\s]+\.js}
    )

    if base_url
      base = URI(base_url)
      body.scan(%r{["']((?:\./|\.\./)?(?:assets/)?[^"'<>\s]+\.js)["']}).flatten.each do |relative|
        next if relative.start_with?("http://", "https://")
        # Ignore bare package-style paths that are not under this CDN module tree.
        next unless relative.start_with?("./", "../", "assets/")

        begin
          urls << URI.join(base, relative).to_s
        rescue URI::InvalidURIError
          next
        end
      end
    end

    prioritize_web_scripts(urls.uniq)
  end

  def prioritize_web_scripts(urls)
    urls.sort_by do |url|
      filename = File.basename(URI(url).path)
      priority = if filename.start_with?("guest-token-")
        0
      elsif filename.start_with?("main.")
        1
      elsif filename.start_with?("entry-") || filename.include?("entry-client")
        2
      else
        3
      end
      [priority, url]
    end
  end

  def web_bearer_token(body)
    body[/Bearer ([A-Za-z0-9%._-]+)/, 1] ||
      body[/["'`](AAAAAAAA[A-Za-z0-9%._-]+)["'`]/, 1]
  end

  def tweet_result_query_id(body)
    body[/queryId:"([^"]+)",operationName:"TweetResultByRestId"/, 1] ||
      body[/operationName:"TweetResultByRestId",queryId:"([^"]+)"/, 1]
  end

  def stream_from_page(url)
    body = normalized_page_body(request_text(url))
    stream_url = body.scan(%r{https://[^"'<>\s\\]+\.m3u8(?:\?[^"'<>\s\\]+)?}).first
    [stream_url, page_thumbnail(body)]
  end

  def page_thumbnail_for(url)
    page_thumbnail(normalized_page_body(request_text(url)))
  rescue StandardError
    nil
  end

  def page_thumbnail(body)
    patterns = [
      /<meta[^>]+(?:property|name)=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']/i,
      /<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']og:image(?::secure_url)?["']/i,
      /<meta[^>]+(?:property|name)=["']twitter:image(?::src)?["'][^>]+content=["']([^"']+)["']/i,
      /<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']twitter:image(?::src)?["']/i,
      /"(?:thumbnail_image_original|thumbnail_image|preview_image_url|image_url_original|image_url_large|image_url_medium|image_url|poster_image|posterImage|thumbnailUrl|thumbnail_url)"\s*:\s*"([^"]+)"/i
    ]
    patterns.each do |pattern|
      value = body[pattern, 1]
      return CGI.unescapeHTML(value.gsub('\\/', '/')) if value
    end
    nil
  end

  def normalized_page_body(body)
    body.gsub('\\/', '/')
      .gsub('\\\\u002F', '/')
      .gsub('\\u002F', '/')
      .gsub('%2F', '/')
      .gsub('%3A', ':')
      .gsub('%3F', '?')
      .gsub('%3D', '=')
      .gsub('%26', '&')
      .gsub('&amp;', '&')
  end

  def request_json(url, method: :get, bearer_token: nil, guest_token: nil)
    JSON.parse(request(url, method: method, bearer_token: bearer_token, guest_token: guest_token))
  end

  def request_text(url)
    request(url)
  end

  def request(url, method: :get, bearer_token: nil, guest_token: nil, redirects: 3)
    uri = URI(url)
    http_request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    http_request["Authorization"] = "Bearer #{bearer_token}" if bearer_token
    http_request["x-guest-token"] = guest_token if guest_token
    http_request["x-twitter-client-language"] = "en" if bearer_token
    http_request["x-twitter-active-user"] = "yes" if bearer_token
    http_request["User-Agent"] = "Mozilla/5.0 SpaceXTV hosted card processor/1.0"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
      http.request(http_request)
    end
    if response.is_a?(Net::HTTPRedirection) && redirects.positive?
      return request(URI.join(url, response["location"]).to_s, method: method, bearer_token: bearer_token, guest_token: guest_token, redirects: redirects - 1)
    end
    unless response.code.to_i.between?(200, 299)
      raise "HTTP #{response.code} for #{url}: #{response.body.to_s[0, 300]}"
    end
    response.body
  end
end
