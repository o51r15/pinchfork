defmodule Pinchflat.Media.SkipReason do
  @moduledoc """
  Why a video that isn't downloaded, waiting or failed was left out. Nothing stores this per
  video (the download rules are evaluated on the fly by MediaQuery.pending/0), so it's worked
  out here with the same rules, first match wins.

  Used by the source page (counts per reason) and the video page (one reason).
  """

  @order [:short, :livestream, :profile_only, :members, :public, :cutoff, :duration, :title, :other]

  @doc "The reasons in display order."
  def order, do: @order

  @doc """
  The reason a media item was skipped, given its source and that source's media profile.

  Returns :short | :livestream | :profile_only | :members | :public | :cutoff | :duration | :title | :other
  """
  def for_item(item, source, profile) do
    prevented = to_string(item.download_prevented_reason)

    cond do
      String.starts_with?(prevented, "policy_members") -> :members
      String.starts_with?(prevented, "policy_public") -> :public
      item.short_form_content == true and profile.shorts_behaviour == :exclude -> :short
      item.livestream == true and profile.livestream_behaviour == :exclude -> :livestream
      not matches_only_rules?(item, profile) -> :profile_only
      before_cutoff?(item, source) -> :cutoff
      outside_duration?(item, source) -> :duration
      not title_matches?(item, source) -> :title
      true -> :other
    end
  end

  @doc """
  The download rule (profile or source) that leaves this item out, or nil if it passes them all.
  Unlike for_item/3 this doesn't look at prevention stamps: it answers "would the download
  rules let this video through?", the same question MediaQuery.pending/0 asks in SQL.

  Returns :short | :livestream | :profile_only | :cutoff | :duration | :title | nil
  """
  def rule(item, source, profile) do
    cond do
      item.short_form_content == true and profile.shorts_behaviour == :exclude -> :short
      item.livestream == true and profile.livestream_behaviour == :exclude -> :livestream
      not matches_only_rules?(item, profile) -> :profile_only
      before_cutoff?(item, source) -> :cutoff
      outside_duration?(item, source) -> :duration
      not title_matches?(item, source) -> :title
      true -> nil
    end
  end

  defp matches_only_rules?(item, %{shorts_behaviour: :only, livestream_behaviour: :only}),
    do: item.short_form_content == true or item.livestream == true

  defp matches_only_rules?(item, %{shorts_behaviour: :only}), do: item.short_form_content == true
  defp matches_only_rules?(item, %{livestream_behaviour: :only}), do: item.livestream == true
  defp matches_only_rules?(_item, _profile), do: true

  defp before_cutoff?(_item, %{download_cutoff_date: nil}), do: false
  defp before_cutoff?(%{uploaded_at: nil}, _source), do: false

  defp before_cutoff?(item, source) do
    Date.compare(DateTime.to_date(item.uploaded_at), source.download_cutoff_date) == :lt
  end

  # Like the SQL in MediaQuery.meets_min_and_max_duration/0: with a limit set, an unknown
  # length doesn't pass (NULL comparisons are never true)
  defp outside_duration?(%{duration_seconds: nil}, source),
    do: not is_nil(source.min_duration_seconds) or not is_nil(source.max_duration_seconds)

  defp outside_duration?(item, source) do
    (source.min_duration_seconds && item.duration_seconds < source.min_duration_seconds) ||
      (source.max_duration_seconds && item.duration_seconds > source.max_duration_seconds) || false
  end

  defp title_matches?(_item, %{title_filter_regex: nil}), do: true

  defp title_matches?(item, source) do
    case Regex.compile(source.title_filter_regex) do
      {:ok, regex} -> Regex.match?(regex, item.title || "")
      _ -> false
    end
  end
end
