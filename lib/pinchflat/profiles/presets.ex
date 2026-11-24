defmodule Pinchflat.Profiles.Presets do
  @moduledoc """
  Ready-made media profile settings. Used by the setup wizard and the media profile form,
  so both start from the same values.
  """

  alias Pinchflat.Profiles.MediaProfile

  @media_center_template "/shows/{{ source_custom_name }}/{{ season_by_year__episode_by_date_and_index }} - {{ title }}.{{ ext }}"
  @audio_template "/music/{{ artist_name }}/{{ title }}.{{ ext }}"

  @doc """
  The presets in display order, each with a key, a name, a one-line summary and attributes.

  Returns [map()]
  """
  def all do
    [
      %{
        key: "default",
        name: "Default",
        summary: "1080p video with subtitles and thumbnails. A good start for most channels.",
        attrs: %{
          name: "Default",
          output_path_template: default_template(),
          download_subs: true,
          embed_subs: true,
          download_auto_subs: false,
          sub_langs: "en",
          download_thumbnail: true,
          embed_thumbnail: true,
          download_metadata: false,
          embed_metadata: true,
          shorts_behaviour: :include,
          livestream_behaviour: :exclude,
          preferred_resolution: :"1080p",
          download_nfo: false,
          download_source_images: false
        }
      },
      %{
        key: "media_center",
        name: "TV & media center",
        summary: "1080p, organised as seasons with NFO files and artwork for Jellyfin, Plex or Kodi.",
        attrs: %{
          name: "TV Shows",
          output_path_template: @media_center_template,
          download_subs: true,
          embed_subs: true,
          download_auto_subs: false,
          sub_langs: "en",
          download_thumbnail: true,
          embed_thumbnail: true,
          download_metadata: false,
          embed_metadata: true,
          shorts_behaviour: :exclude,
          livestream_behaviour: :exclude,
          preferred_resolution: :"1080p",
          redownload_delay_days: 1,
          download_nfo: true,
          download_source_images: true
        }
      },
      %{
        key: "audio",
        name: "Music",
        summary: "Audio only, filed by artist, with embedded artwork.",
        attrs: %{
          name: "Music",
          output_path_template: @audio_template,
          download_subs: false,
          embed_subs: false,
          download_auto_subs: false,
          sub_langs: "",
          download_thumbnail: false,
          embed_thumbnail: true,
          download_metadata: false,
          embed_metadata: true,
          shorts_behaviour: :exclude,
          livestream_behaviour: :exclude,
          preferred_resolution: :audio,
          download_nfo: false,
          download_source_images: false
        }
      },
      %{
        key: "archiving",
        name: "Archive",
        summary: "Best quality up to 4K, keeps everything including shorts, livestreams and metadata.",
        attrs: %{
          name: "Archive",
          output_path_template: default_template(),
          download_subs: true,
          embed_subs: true,
          download_auto_subs: false,
          sub_langs: "all",
          download_thumbnail: true,
          embed_thumbnail: true,
          download_metadata: true,
          embed_metadata: true,
          shorts_behaviour: :include,
          livestream_behaviour: :include,
          preferred_resolution: :"2160p",
          redownload_delay_days: 1,
          download_nfo: false,
          download_source_images: true
        }
      }
    ]
  end

  @doc """
  Looks up a preset by key.

  Returns map() | nil
  """
  def get(key), do: Enum.find(all(), &(&1.key == key))

  defp default_template, do: %MediaProfile{}.output_path_template
end
