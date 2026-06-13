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
