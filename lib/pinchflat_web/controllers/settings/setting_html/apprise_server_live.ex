defmodule Pinchflat.Settings.AppriseServerLive do
  use PinchflatWeb, :live_view

  alias PinchflatWeb.Settings.SettingHTML

  # Pushover Apprise URL format: pover://<user_key>@<api_token>
  @pushover_prefix "pover://"

  def render(assigns) do
    ~H"""
    <div>
      <%!-- Notification type tabs --%>
      <div class="flex gap-4 mb-4 mt-2">
        <button
          type="button"
          class={[
            "px-4 py-2 rounded-md text-sm font-medium transition-colors",
            if(@mode == :pushover,
              do: "bg-primary text-white",
              else: "bg-meta-4 text-bodydark1 hover:bg-graydark"
            )
          ]}
          phx-click="set_mode"
          phx-value-mode="pushover"
        >
          Pushover
        </button>
        <button
          type="button"
          class={[
            "px-4 py-2 rounded-md text-sm font-medium transition-colors",
            if(@mode == :custom,
              do: "bg-primary text-white",
              else: "bg-meta-4 text-bodydark1 hover:bg-graydark"
            )
          ]}
          phx-click="set_mode"
          phx-value-mode="custom"
        >
          Custom Apprise URL
        </button>
      </div>

      <%!-- Pushover mode --%>
      <div :if={@mode == :pushover}>
        <p class="text-sm text-bodydark1 mb-3">
          Enter your Pushover credentials. Find your User Key at
          <a href="https://pushover.net" target="_blank" class="underline">pushover.net</a>
          and your API Token from your Pushover application.
        </p>
        <div class="flex flex-col gap-3">
          <.input
            type="text"
            id="pushover_user_key"
            name="pushover_user_key"
            value={@pushover_user_key}
            label="User Key"
            placeholder="uQiRzpo4DXghDmr9QzzfQu27cmVRsG"
            inputclass="font-mono text-sm"
            phx-change="pushover_changed"
          />
          <.input
            type="text"
            id="pushover_api_token"
            name="pushover_api_token"
            value={@pushover_api_token}
            label="API Token"
            placeholder="azGDORePK8gMaC0QOYAMyEEuzJnyUi"
            inputclass="font-mono text-sm"
            phx-change="pushover_changed"
          />
        </div>
        <%!-- Hidden field carries the assembled pover:// URL to the settings form --%>
        <input type="hidden" name="setting[apprise_server]" value={@value} />
        <div class="mt-3 flex items-center gap-3">
          <.icon_button icon_name={@icon_name} class="h-12 w-12" phx-click="send_apprise_test" tooltip={@tooltip} />
          <span class="text-xs text-bodydark1 font-mono">{@value}</span>
        </div>
      </div>

      <%!-- Custom Apprise URL mode --%>
      <div :if={@mode == :custom}>
        <.input
          type="text"
          id="setting_apprise_server"
          name="setting[apprise_server]"
          value={@value}
          label="Apprise Server URL"
          help={SettingHTML.apprise_server_help()}
          html_help={true}
          inputclass="font-mono text-sm mr-4"
          placeholder="https://discordapp.com/api/webhooks/{WebhookID}/{WebhookToken}"
          phx-change="apprise_server_changed"
        >
          <:input_append>
            <.icon_button icon_name={@icon_name} class="h-12 w-12" phx-click="send_apprise_test" tooltip={@tooltip} />
          </:input_append>
        </.input>
      </div>
    </div>
    """
  end

  def mount(_params, session, socket) do
    value = session["value"] || ""
    {mode, user_key, api_token} = parse_value(value)

    new_assigns = %{
      value: value,
      mode: mode,
      pushover_user_key: user_key,
      pushover_api_token: api_token,
      icon_name: "hero-paper-airplane",
      tooltip: "Send Test"
    }

    {:ok, assign(socket, new_assigns)}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :mode, String.to_existing_atom(mode))}
  end

  def handle_event("pushover_changed", params, %{assigns: assigns} = socket) do
    user_key = Map.get(params, "pushover_user_key", assigns.pushover_user_key)
    api_token = Map.get(params, "pushover_api_token", assigns.pushover_api_token)

    value =
      if user_key != "" and api_token != "" do
        "#{@pushover_prefix}#{user_key}@#{api_token}"
      else
        ""
      end

    {:noreply, assign(socket, %{pushover_user_key: user_key, pushover_api_token: api_token, value: value})}
  end

  def handle_event("apprise_server_changed", %{"setting" => setting}, socket) do
    {:noreply, assign(socket, %{value: setting["apprise_server"]})}
  end

  def handle_event("send_apprise_test", _params, %{assigns: assigns} = socket) do
    backend_runner().run([assigns.value], title: "Pinchfork Test", body: "This is a test message from Pinchfork")
    Process.send_after(self(), :reset_button_icon, 4_000)

    {:noreply, assign(socket, %{icon_name: "hero-check", tooltip: "Sent!"})}
  end

  def handle_info(:reset_button_icon, socket) do
    {:noreply, assign(socket, %{icon_name: "hero-paper-airplane", tooltip: "Send Test"})}
  end

  # Detect whether the stored value is a Pushover URL and parse it back into fields.
  # pover://user_key@api_token
  defp parse_value(@pushover_prefix <> rest) do
    case String.split(rest, "@", parts: 2) do
      [user_key, api_token] -> {:pushover, user_key, api_token}
      _ -> {:pushover, "", ""}
    end
  end

  defp parse_value(_), do: {:custom, "", ""}

  defp backend_runner do
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
