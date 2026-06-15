defmodule Pinchflat.Downloading.StagingCleanerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Downloading.StagingCleaner
  alias Pinchflat.Downloading.StagingPaths

  setup do
    # Restore whatever LOCALTEMP was (usually nothing) after each test.
    original = System.get_env("LOCALTEMP")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("LOCALTEMP")
        val -> System.put_env("LOCALTEMP", val)
      end
    end)

    media_profile = media_profile_fixture()
    source = source_fixture(%{media_profile_id: media_profile.id})
    media_item = media_item_fixture(source_id: source.id)

    {:ok, media_item: media_item}
  end

  describe "enabled?/0" do
    test "true only when LOCALTEMP is exactly \"true\"" do
      System.put_env("LOCALTEMP", "true")
      assert StagingCleaner.enabled?()

      System.put_env("LOCALTEMP", "false")
      refute StagingCleaner.enabled?()

      System.delete_env("LOCALTEMP")
      refute StagingCleaner.enabled?()
    end
  end

  describe "clean/1 when LOCALTEMP is disabled" do
    test "is a no-op and returns :ok", %{media_item: media_item} do
      System.delete_env("LOCALTEMP")
      assert :ok = StagingCleaner.clean(media_item)
    end
  end

  describe "clean/1 when LOCALTEMP is enabled" do
    setup do
      System.put_env("LOCALTEMP", "true")
      :ok
    end

    test "returns :ok when the staging dir does not exist", %{media_item: media_item} do
      # Derivation points at the hardcoded base, which won't exist in the test env. rm_rf on a
      # missing path is a successful no-op, so this must still return :ok and never raise.
      assert :ok = StagingCleaner.clean(media_item)
    end

    test "derives a per-item directory under the staging base keyed on media_id", %{media_item: media_item} do
      dir = StagingPaths.staging_dir_for(media_item)

      assert dir == Path.join(StagingPaths.staging_base(), media_item.media_id)
    end

    test "two different items derive two different directories", %{media_item: media_item} do
      other_source = source_fixture()
      other_item = media_item_fixture(source_id: other_source.id)

      refute StagingPaths.staging_dir_for(media_item) == StagingPaths.staging_dir_for(other_item)
    end

    test "never raises even if given an item with a weird media_id", %{media_item: media_item} do
      weird = %{media_item | media_id: "../../etc/evil id with spaces"}

      # Sanitization must keep the derived path under the staging base, and clean must not raise.
      dir = StagingPaths.staging_dir_for(weird)
      assert String.starts_with?(dir, StagingPaths.staging_base() <> "/")
      refute String.contains?(dir, "..")

      assert :ok = StagingCleaner.clean(weird)
    end
  end

  describe "StagingPaths.staging_dir_for/1 sanitization" do
    test "replaces path-unsafe characters with underscores" do
      item = %Pinchflat.Media.MediaItem{media_id: "a b/c..d"}

      dir = StagingPaths.staging_dir_for(item)

      # spaces, slash, and the double-dot run all become underscores; result stays under base
      assert dir == Path.join(StagingPaths.staging_base(), "a_b_c__d")
    end

    test "falls back to a safe name for nil or empty-after-sanitize ids" do
      assert StagingPaths.staging_dir_for(%Pinchflat.Media.MediaItem{media_id: nil}) ==
               Path.join(StagingPaths.staging_base(), "_unknown")

      assert StagingPaths.staging_dir_for(%Pinchflat.Media.MediaItem{media_id: ".."}) ==
               Path.join(StagingPaths.staging_base(), "_unknown")
    end
  end
end
