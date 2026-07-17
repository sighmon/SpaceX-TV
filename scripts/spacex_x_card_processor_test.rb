require "minitest/autorun"
require_relative "spacex_x_card_processor"

class SpaceXXCardProcessorTest < Minitest::Test
  NOW = Time.utc(2026, 6, 13, 0, 0, 0)

  class StubProcessor < SpaceXXCardProcessor
    private

    def resolve_broadcast(_value)
      {
        stream_url: "https://video.pscp.tv/replay.m3u8",
        thumbnail_url: "https://pbs.twimg.com/replay.jpg",
        is_live: false
      }
    end

    def stream_from_page(_url)
      [nil, nil]
    end

    def page_thumbnail_for(_url)
      "https://pbs.twimg.com/broadcast-page.jpg"
    end
  end

  def test_processes_api_video_gallery_broadcast_and_negative_cards
    entries = StubProcessor.new(now: NOW).process(response).fetch("entries")

    assert_equal "https://video.twimg.com/high.mp4", entries.fetch("post:video").fetch("streamURL")
    assert_equal "gallery", entries.fetch("post:gallery").fetch("contentKind")
    assert_nil entries.fetch("post:gallery").fetch("expiresAt")
    assert_equal "https://video.pscp.tv/replay.m3u8", entries.fetch("post:broadcast").fetch("streamURL")
    assert_equal false, entries.fetch("post:broadcast").fetch("isLive")
    assert_equal "https://video.twimg.com/repost-high.mp4", entries.fetch("post:repost").fetch("streamURL")
    assert_equal false, entries.fetch("post:plain").fetch("hasUsableContent")
  end

  class NotStartedStubProcessor < SpaceXXCardProcessor
    private

    def resolve_broadcast(_value)
      {
        stream_url: nil,
        thumbnail_url: "https://pbs.twimg.com/pre-live.jpg",
        is_live: false
      }
    end

    def stream_from_page(_url)
      [nil, nil]
    end
  end

  def test_not_started_broadcast_remains_usable_with_short_ttl
    value = response
    value["data"] = value.fetch("data").select { |post| post.fetch("id") == "broadcast" }

    entry = NotStartedStubProcessor.new(now: NOW).process(value).dig("entries", "post:broadcast")

    assert entry.fetch("hasUsableContent")
    assert_nil entry.fetch("streamURL")
    assert_equal false, entry.fetch("isLive")
    assert_equal "https://pbs.twimg.com/pre-live.jpg", entry.fetch("thumbnailURL")
    # Re-check soon so the HLS URL appears once X starts the stream.
    assert_equal (NOW + SpaceXXCardProcessor::LIVE_TTL).iso8601, entry.fetch("expiresAt")
  end

  def test_not_started_broadcast_state_helper
    processor = SpaceXXCardProcessor.new(now: NOW)
    assert processor.send(:not_started_broadcast_state?, "NOT_STARTED")
    assert processor.send(:not_started_broadcast_state?, "pre_published")
    refute processor.send(:not_started_broadcast_state?, "RUNNING")
    refute processor.send(:not_started_broadcast_state?, nil)
  end

  class NotStartedPageThumbnailFailsProcessor < SpaceXXCardProcessor
    private

    def request_json(url, bearer_token:, guest_token: nil, method: :get)
      if url.include?("broadcasts/show.json")
        {
          "broadcasts" => {
            "abc123" => {
              "media_key" => "28_1",
              "state" => "NOT_STARTED",
              "status" => "Pre-live",
              "pre_live_slate_url" => "https://pbs.twimg.com/slate.jpg"
            }
          }
        }
      else
        raise "unexpected request_json: #{url}"
      end
    end

    def activate_guest(_bearer_token)
      "guest"
    end

    def web_configuration
      { bearer_token: "token", query_id: "qid" }
    end

    def page_thumbnail_for(_url)
      # Soft-fail seam: production page_thumbnail_for rescues to nil.
      nil
    end
  end

  def test_not_started_survives_page_thumbnail_failure
    processor = NotStartedPageThumbnailFailsProcessor.new(now: NOW)
    resolved = processor.send(:resolve_broadcast, "https://x.com/i/broadcasts/abc123")

    assert_nil resolved[:stream_url]
    assert_equal false, resolved[:is_live]
    assert_equal "https://pbs.twimg.com/slate.jpg", resolved[:thumbnail_url]
  end

  class NotStartedTweetWithoutMediaKeyProcessor < SpaceXXCardProcessor
    private

    def request_json(url, bearer_token:, guest_token: nil, method: :get)
      if url.include?("broadcasts/show.json")
        raise "force tweet path"
      end
      if url.include?("TweetResultByRestId")
        {
          "data" => {
            "tweetResult" => {
              "result" => {
                "card" => {
                  "legacy" => {
                    "binding_values" => [
                      {
                        "key" => "broadcast_state",
                        "value" => { "string_value" => "NOT_STARTED" }
                      },
                      {
                        "key" => "broadcast_pre_live_slate_x_large",
                        "value" => { "image_value" => { "url" => "https://pbs.twimg.com/tweet-slate.jpg" } }
                      }
                    ]
                  }
                }
              }
            }
          }
        }
      else
        raise "unexpected request_json: #{url}"
      end
    end

    def activate_guest(_bearer_token)
      "guest"
    end

    def web_configuration
      { bearer_token: "token", query_id: "qid" }
    end
  end

  def test_not_started_tweet_path_without_media_key
    processor = NotStartedTweetWithoutMediaKeyProcessor.new(now: NOW)
    # Numeric id forces tweet GraphQL fallback after show.json fails.
    resolved = processor.send(:resolve_broadcast, "https://x.com/i/broadcasts/1234567890")

    assert_nil resolved[:stream_url]
    assert_equal false, resolved[:is_live]
    assert_equal "https://pbs.twimg.com/tweet-slate.jpg", resolved[:thumbnail_url]
  end

  def test_multi_video_posts_remain_video_kind_for_older_apps
    value = response
    value.fetch("data") << post("multi-video", media_keys: %w[video-media video-media-2])
    value.fetch("includes").fetch("media") << {
      "media_key" => "video-media-2",
      "type" => "video",
      "preview_image_url" => "https://pbs.twimg.com/video-2.jpg",
      "variants" => [
        { "bit_rate" => 1_280_000, "content_type" => "video/mp4", "url" => "https://video.twimg.com/second.mp4" }
      ]
    }

    entry = StubProcessor.new(now: NOW).process(value).dig("entries", "post:multi-video")

    # contentKind stays "video" so previous app versions can decode processed_cards.
    assert_equal "video", entry.fetch("contentKind")
    assert_equal "https://video.twimg.com/high.mp4", entry.fetch("streamURL")
    assert entry.fetch("hasUsableContent")
  end

  def test_mixed_video_and_photo_posts_remain_video_kind_for_older_apps
    value = response
    value.fetch("data") << post("mixed", media_keys: %w[video-media photo-media])

    entry = StubProcessor.new(now: NOW).process(value).dig("entries", "post:mixed")

    assert_equal "video", entry.fetch("contentKind")
    assert_equal "https://video.twimg.com/high.mp4", entry.fetch("streamURL")
  end

  def test_reuses_unchanged_unexpired_entries
    first = StubProcessor.new(now: NOW).process(response)
    existing_cache = { "processed_cards" => first }
    second = StubProcessor.new(existing_cache: existing_cache, now: NOW + 60).process(response)

    assert_equal(
      first.dig("entries", "post:video", "lastChecked"),
      second.dig("entries", "post:video", "lastChecked")
    )
  end

  def test_uses_largest_entity_image_like_the_app
    value = response
    broadcast = value.fetch("data").find { |post| post.fetch("id") == "broadcast" }
    broadcast.fetch("entities").fetch("urls").first["images"] = [
      { "url" => "https://pbs.twimg.com/card-small.jpg", "width" => 320, "height" => 180 },
      { "url" => "https://pbs.twimg.com/card-large.jpg", "width" => 1280, "height" => 720 }
    ]

    entry = StubProcessor.new(now: NOW).process(value).dig("entries", "post:broadcast")

    assert_equal "https://pbs.twimg.com/card-large.jpg", entry.fetch("thumbnailURL")
  end

  def test_does_not_reuse_entries_from_an_older_processor_version
    first = StubProcessor.new(now: NOW).process(response)
    first["version"] = SpaceXXCardProcessor::CACHE_VERSION - 1

    second = StubProcessor.new(existing_cache: { "processed_cards" => first }, now: NOW + 60).process(response)

    refute_equal(
      first.dig("entries", "post:video", "lastChecked"),
      second.dig("entries", "post:video", "lastChecked")
    )
  end

  def test_parses_twitter_image_when_content_comes_before_name
    processor = StubProcessor.new(now: NOW)
    body = '<meta content="https://pbs.twimg.com/card.jpg" name="twitter:image">'

    assert_equal "https://pbs.twimg.com/card.jpg", processor.send(:page_thumbnail, body)
  end

  def test_discovers_current_and_legacy_x_web_scripts_with_guest_token_first
    processor = StubProcessor.new(now: NOW)
    body = <<~HTML
      <link href="https://abs.twimg.com/x-web/x-web/assets/chunk-current.js">
      <script src="https://abs.twimg.com/responsive-web/client-web/main.legacy.js"></script>
      <link href="https://abs.twimg.com/x-web/x-web/assets/guest-token-current.js">
    HTML

    assert_equal(
      [
        "https://abs.twimg.com/x-web/x-web/assets/guest-token-current.js",
        "https://abs.twimg.com/responsive-web/client-web/main.legacy.js",
        "https://abs.twimg.com/x-web/x-web/assets/chunk-current.js"
      ],
      processor.send(:web_script_urls, body)
    )
  end

  private

  def response
    {
      "data" => [
        post("video", media_keys: ["video-media"]),
        post("gallery", media_keys: ["photo-media"]),
        post("broadcast", url: "https://x.com/i/broadcasts/abc123"),
        post("repost", referenced_tweets: [{ "type" => "retweeted", "id" => "reposted-video" }]),
        post("plain")
      ],
      "includes" => {
        "media" => [
          {
            "media_key" => "video-media",
            "type" => "video",
            "preview_image_url" => "https://pbs.twimg.com/video.jpg",
            "variants" => [
              { "bit_rate" => 256_000, "content_type" => "video/mp4", "url" => "https://video.twimg.com/low.mp4" },
              { "bit_rate" => 2_176_000, "content_type" => "video/mp4", "url" => "https://video.twimg.com/high.mp4" }
            ]
          },
          {
            "media_key" => "photo-media",
            "type" => "photo",
            "url" => "https://pbs.twimg.com/media/photo.jpg?format=jpg&name=small",
            "width" => 1600,
            "height" => 900
          },
          {
            "media_key" => "repost-video-media",
            "type" => "video",
            "preview_image_url" => "https://pbs.twimg.com/repost-video.jpg",
            "variants" => [
              { "bit_rate" => 832_000, "content_type" => "video/mp4", "url" => "https://video.twimg.com/repost-high.mp4" }
            ]
          }
        ],
        "tweets" => [
          post("reposted-video", media_keys: ["repost-video-media"])
        ]
      }
    }
  end

  def post(id, media_keys: nil, url: nil, referenced_tweets: nil)
    value = {
      "id" => id,
      "text" => "Post #{id}",
      "created_at" => "2026-06-12T00:00:00.000Z"
    }
    value["attachments"] = { "media_keys" => media_keys } if media_keys
    value["referenced_tweets"] = referenced_tweets if referenced_tweets
    if url
      value["entities"] = {
        "urls" => [{ "expanded_url" => url }]
      }
    end
    value
  end
end
