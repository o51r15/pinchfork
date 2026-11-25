defmodule PinchflatWeb.MediaProfiles.MediaProfileHTML do
  use PinchflatWeb, :html

  embed_templates "media_profile_html/*"

  def frieldly_sponsorblock_categories do
    [
      {"Sponsor", "sponsor"},
      {"Intro/Intermission", "intro"},
      {"Outro/Credits", "outro"},
      {"Self Promotion", "selfpromo"},
      {"Preview/Recap", "preview"},
      {"Filler Tangent", "filler"},
      {"Interaction Reminder", "interaction"},
      {"Non-music Section", "music_offtopic"}
    ]
  end

  def media_center_custom_output_template_options do
    [
      season_by_year__episode_by_date: "<code>Season YYYY/sYYYYeMMDD</code>",
      season_by_year__episode_by_date_and_index:
        "same as the above but it handles dates better. <strong>This is the recommended option</strong>",
      static_season__episode_by_index:
        "<code>Season 1/s01eXX</code> where <code>XX</code> is the video's position in the playlist. Only recommended for playlists (not channels) that don't change",
      static_season__episode_by_date:
        "<code>Season 1/s01eYYMMDD</code>. Recommended for playlists that might change or where order isn't important"
    ]
  end

  def other_custom_output_template_options do
    [
      upload_day: nil,
      upload_month: nil,
      upload_year: nil,
      upload_yyyy_mm_dd: "the upload date in the format <code>YYYY-MM-DD</code>",
      source_custom_name: "the name of the sources that use this profile",
      source_collection_id: "the YouTube ID of the sources that use this profile",
      source_collection_name:
        "the YouTube name of the sources that use this profile (often the same as source_custom_name)",
      source_collection_type: "the collection type of the sources using this profile. Either 'channel' or 'playlist'",
      artist_name: "the name of the artist with fallbacks to other uploader fields",
      season_from_date: "alias for upload_year",
      season_episode_from_date: "the upload date formatted as <code>sYYYYeMMDD</code>",
      season_episode_index_from_date:
        "the upload date formatted as <code>sYYYYeMMDDII</code> where <code>II</code> is an index to prevent date collisions",
      media_playlist_index:
        "the place of the media item in the playlist. Do not use with channels. May not work if the playlist is updated",
      media_item_id: "the ID of the media item in Pinchflat's database",
      source_id: "the ID of the source in Pinchflat's database",
      media_profile_id: "the ID of the media profile in Pinchflat's database"
    ]
  end

  def common_output_template_options do
    ~w(
      id
      ext
      title
      uploader
      channel
      upload_date
      duration_string
    )a
  end
end
