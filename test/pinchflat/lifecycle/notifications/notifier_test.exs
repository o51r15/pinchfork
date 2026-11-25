defmodule Pinchflat.Lifecycle.Notifications.NotifierTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings
  alias Pinchflat.Sources
  alias Pinchflat.Health.CheckWorker
  alias Pinchflat.Lifecycle.Notifications.Notifier

  @full_disk %{path: "/downloads", total: 1_000_000_000_000, used: 990_000_000_000, free: 10_000_000_000, used_pct: 99}
  @roomy_disk %{
    path: "/downloads",
    total: 1_000_000_000_000,
    used: 100_000_000_000,
    free: 900_000_000_000,
    used_pct: 10
  }

  describe "notify/3" do
    test "sends nothing without a server" do
      Settings.set(notify_source_added: true)
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      assert Notifier.notify(:source_added, "Source added", "A") == :skipped
    end

    test "sends nothing while the event is off" do
      Settings.set(apprise_server: "ntfys://ntfy.sh/topic")
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      assert Notifier.notify(:source_added, "Source added", "A") == :skipped
    end

    test "sends to every server, with the Pinchfork title" do
      Settings.set(apprise_server: "ntfys://ntfy.sh/a  tgram://b")
      Settings.set(notify_source_added: true)

      expect(AppriseRunnerMock, :run, fn ["ntfys://ntfy.sh/a", "tgram://b"], opts ->
        assert opts == [title: "[Pinchfork] Source added", body: "A"]
        {:ok, ""}
      end)

      assert Notifier.notify(:source_added, "Source added", "A") == :ok
    end

    test "a failed send is returned, not raised" do
      Settings.set(apprise_server: "ntfys://ntfy.sh/a")
      Settings.set(notify_source_added: true)
      expect(AppriseRunnerMock, :run, fn _, _ -> {:error, "boom"} end)

      assert Notifier.notify(:source_added, "Source added", "A") == {:error, "boom"}
    end

    test "only 'New videos found' is on to begin with" do
      setting = Settings.record()

      assert Enum.filter(Notifier.events(), &Notifier.event_on?(setting, &1.event)) |> Enum.map(& &1.event) ==
               [:new_media]
    end
  end

  describe "send_sample/2" do
    test "sends the example even while the event is off" do
      expect(AppriseRunnerMock, :run, fn ["ntfys://x"], opts ->
        assert opts[:title] == "[Pinchfork] Download failed (test)"
        {:ok, ""}
      end)

      assert Notifier.send_sample(:download_failed, "ntfys://x") == :ok
    end

    test "needs a server" do
      assert Notifier.send_sample(:download_failed, "") == {:error, "Enter a server first."}
    end
  end

  describe "source events" do
    setup do
      Settings.set(apprise_server: "ntfys://x")
      Settings.set(notify_source_removed: true)
      :ok
    end

    test "removing a source sends Source removed" do
      source = source_fixture(custom_name: "Old Channel")

      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts == [title: "[Pinchfork] Source removed", body: "Old Channel"]
        {:ok, ""}
      end)

      assert {:ok, _} = Sources.delete_source(source)
    end
  end

  describe "problems (Health.CheckWorker)" do
    setup do
      Settings.set(apprise_server: "ntfys://x")
      Settings.set(notify_problems: true)
      :ok
    end

    test "a new problem is sent once, and again when it's fixed" do
      parent = self()

      stub(AppriseRunnerMock, :run, fn _, opts ->
        send(parent, {:sent, opts[:title], opts[:body]})
        {:ok, ""}
      end)

      full = [po_status: fn -> :up end, disk: fn -> @full_disk end]
      roomy = [po_status: fn -> :up end, disk: fn -> @roomy_disk end]

      CheckWorker.check(full)
      assert_received {:sent, "[Pinchfork] Problem", "The download disk is nearly full: 10.0 GB free."}
      assert Settings.get!(:health_problems) == ["disk"]

      CheckWorker.check(full)
      refute_received {:sent, _, _}

      CheckWorker.check(roomy)
      assert_received {:sent, "[Pinchfork] Fixed", "The download disk has enough free space again."}
      assert Settings.get!(:health_problems) == []
    end

    test "the token server not answering is a problem" do
      expect(AppriseRunnerMock, :run, fn _, opts ->
        assert opts[:body] =~ "PO token server isn't answering"
        {:ok, ""}
      end)

      CheckWorker.check(po_status: fn -> :down end, disk: fn -> nil end)
    end

    test "problems are remembered while the notification is off" do
      Settings.set(notify_problems: false)
      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      CheckWorker.check(po_status: fn -> :down end, disk: fn -> nil end)

      assert Settings.get!(:health_problems) == ["po_token"]
    end
  end
end
