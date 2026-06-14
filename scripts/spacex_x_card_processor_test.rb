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
    assert_equal false, entries.fetch("post:plain").fetch("hasUsableContent")
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

  private

  def response
    {
      "data" => [
        post("video", media_keys: ["video-media"]),
        post("gallery", media_keys: ["photo-media"]),
        post("broadcast", url: "https://x.com/i/broadcasts/abc123"),
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
          }
        ]
      }
    }
  end

  def post(id, media_keys: nil, url: nil)
    value = {
      "id" => id,
      "text" => "Post #{id}",
      "created_at" => "2026-06-12T00:00:00.000Z"
    }
    value["attachments"] = { "media_keys" => media_keys } if media_keys
    if url
      value["entities"] = {
        "urls" => [{ "expanded_url" => url }]
      }
    end
    value
  end
end
