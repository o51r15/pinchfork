defmodule Pinchflat.Sources.DefaultVideoClientTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Settings
  alias Pinchflat.Downloading.DownloadOptionBuilder

  defp player_client(source) do
    item = Repo.preload(media_item_fixture(source_id: source.id), source: :media_profile)
    {:ok, opts} = DownloadOptionBuilder.build(item)

    Enum.find_value(opts, fn
      {:extractor_args, "youtube:player_client=" <> chain} -> chain
      _ -> nil
    end)
  end

  describe "effective_client/2" do
    test "is automatic while the default is off" do
      Settings.set(default_client: "android_vr")

      assert Sources.effective_client(source_fixture()) == {nil, :automatic}
    end

    test "uses the default for a source without its own client" do
      Settings.set(default_client_enabled: true)
      Settings.set(default_client: "android_vr")

      assert Sources.effective_client(source_fixture()) == {"android_vr", :default}
    end

    test "a source's own client wins over the default" do
      Settings.set(default_client_enabled: true)
      source = source_fixture(client_override: "tv")

      assert Sources.effective_client(source) == {"tv", :source}
    end

    test "a default without cookie support isn't applied to a source that uses cookies" do
      Settings.set(default_client_enabled: true)
      Settings.set(default_client: "android_vr")

      assert Sources.effective_client(source_fixture(cookie_behaviour: :when_needed)) == {nil, :automatic_cookies}
      assert Sources.effective_client(source_fixture(download_members_videos: true)) == {nil, :automatic_cookies}
    end

    test "a cookie-compatible default is applied to a source that uses cookies" do
      Settings.set(default_client_enabled: true)
      Settings.set(default_client: "web_creator,tv")

      assert Sources.effective_client(source_fixture(cookie_behaviour: :when_needed)) == {"web_creator,tv", :default}
    end
  end

  describe "downloads" do
    test "pass no client while the default is off" do
      assert player_client(source_fixture()) == nil
    end

    test "pass the default client" do
      Settings.set(default_client_enabled: true)

      assert player_client(source_fixture()) == "web_creator,tv"
    end

    test "pass the source's own client over the default" do
      Settings.set(default_client_enabled: true)

      assert player_client(source_fixture(client_override: "android_vr")) == "android_vr"
    end
  end

  describe "the setting" do
    test "rejects unknown clients" do
      assert {:error, changeset} = Settings.set(default_client: "web,nope")
      assert "contains unknown client(s): nope" in errors_on(changeset).default_client
    end

    test "rejects a client list with no clients in it" do
      assert {:error, changeset} = Settings.set(default_client: ",")
      assert "choose a client" in errors_on(changeset).default_client
    end

    test "a blank client falls back to the column default" do
      Settings.set(default_client: "tv")
      Settings.set(default_client: "")

      assert Settings.get!(:default_client) == "web_creator,tv"
    end
  end
end
