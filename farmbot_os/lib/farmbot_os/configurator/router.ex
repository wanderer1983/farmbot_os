defmodule FarmbotOS.Configurator.Router do
  @moduledoc "Routes web connections for configuring farmbot os"
  require FarmbotCore.Logger

  import Phoenix.HTML
  use Plug.Router
  use Plug.Debugger, otp_app: :farmbot
  plug(Plug.Static, from: {:farmbot, "priv/static"}, at: "/")
  plug(Plug.Logger, log: :debug)
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart])
  plug(Plug.Session, store: :ets, key: "_farmbot_session", table: :configurator_session)
  plug(:fetch_session)
  plug(:match)
  plug(:dispatch)

  @data_layer Application.get_env(:farmbot, FarmbotOS.Configurator)[:data_layer]
  @network_layer Application.get_env(:farmbot, FarmbotOS.Configurator)[:network_layer]

  get "/generate_204" do
    send_resp(conn, 204, "")
  end

  get "/gen_204" do
    send_resp(conn, 204, "")
  end

  get "/" do
    case load_last_reset_reason() do
      {:ok, reason} when is_binary(reason) ->
        if String.contains?(reason, "CeleryScript request.") do
          render_page(conn, "index", version: version(), last_reset_reason: nil)
        else
          render_page(conn, "index",
            version: version(),
            last_reset_reason: Phoenix.HTML.raw(reason)
          )
        end

      nil ->
        render_page(conn, "index", version: version(), last_reset_reason: nil)
    end
  end

  get "/view_logs" do
    render_page(conn, "view_logs", logs: dump_logs())
  end

  get "/logs" do
    case dump_log_db() do
      {:ok, data} ->
        md5 = data |> :erlang.md5() |> Base.encode16()

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header(
          "Content-Disposition",
          "inline; filename=\"#{version()}-#{md5}-logs.sqlite3\""
        )
        |> send_resp(200, data)

      {:error, posix} ->
        send_resp(conn, 404, "Error downloading file: #{posix}")
    end
  end

  get("/setup", do: redir(conn, "/"))

  # NETWORKCONFIG
  get "/network" do
    render_page(conn, "network",
      interfaces: list_interfaces(),
      post_action: "select_interface"
    )
  end

  post "select_interface" do
    {:ok, _, conn} = read_body(conn)
    ifname = conn.body_params["interface"] |> remove_empty_string()

    case ifname do
      nil ->
        redir(conn, "/network")

      <<"w", _::binary>> ->
        conn
        |> put_session("iftype", "wireless")
        |> put_session("ifname", ifname)
        |> redir("/config_wireless")

      _ ->
        conn
        |> put_session("iftype", "wired")
        |> put_session("ifname", ifname)
        |> redir("/config_wired")
    end
  end

  get "/config_wired" do
    ifname = get_session(conn, "ifname")

    render_page(conn, "config_wired",
      ifname: ifname,
      advanced_network: advanced_network()
    )
  end

  get "/config_wireless" do
    ifname = get_session("ifname")

    render_page(conn, "/config_wireless_step_1",
      ifname: ifname,
      ssids: scan(ifname),
      post_action: "config_wireless_step_1"
    )
  end

  post "config_wireless_step_1" do
    ifname = get_session("ifname")
    ssid = conn.params["ssid"] |> remove_empty_string()
    security = conn.params["security"] |> remove_empty_string()
    manualssid = conn.params["manualssid"] |> remove_empty_string()

    opts = [
      ssid: ssid,
      ifname: ifname,
      security: security,
      advanced_network: advanced_network(),
      post_action: "config_network"
    ]

    cond do
      manualssid != nil ->
        render_page(
          conn,
          "/config_wireless_step_2_custom",
          Keyword.put(opts, :ssid, manualssid)
        )

      ssid == nil ->
        redir(conn, "/config_wireless")

      security == nil ->
        redir(conn, "/config_wireless")

      security == "WPA-PSK" ->
        render_page(conn, "/config_wireless_step_2_PSK", opts)

      security == "WPA2-PSK" ->
        render_page(conn, "/config_wireless_step_2_PSK", opts)

      security == "WPA-EAP" ->
        render_page(conn, "/config_wireless_step_2_EAP", opts)

      security == "NONE" ->
        render_page(conn, "/config_wireless_step_2_NONE", opts)

      true ->
        render_page(conn, "/config_wireless_step_2_other", opts)
    end
  end

  post "/config_network" do
    # Global configuration data
    dns_name = conn.params["dns_name"] |> remove_empty_string()
    ntp1 = conn.params["ntp_server_1"] |> remove_empty_string()
    ntp2 = conn.params["ntp_server_2"] |> remove_empty_string()
    ssh_key = conn.params["ssh_key"] |> remove_empty_string()

    # Network Interface configuration data
    ssid = conn.params["ssid"] |> remove_empty_string()
    security = conn.params["security"] |> remove_empty_string()
    psk = conn.params["psk"] |> remove_empty_string()
    identity = conn.params["identity"] |> remove_empty_string()
    password = conn.params["password"] |> remove_empty_string()
    domain = conn.params["domain"] |> remove_empty_string()
    name_servers = conn.params["name_servers"] |> remove_empty_string()
    ipv4_method = conn.params["ipv4_method"] |> remove_empty_string()
    ipv4_address = conn.params["ipv4_address"] |> remove_empty_string()
    ipv4_gateway = conn.params["ipv4_gateway"] |> remove_empty_string()
    ipv4_subnet_mask = conn.params["ipv4_subnet_mask"] |> remove_empty_string()
    reg_domain = conn.params["regulatory_domain"] |> remove_empty_string()

    conn
    |> put_session("net_config_dns_name", dns_name)
    |> put_session("net_config_ntp1", ntp1)
    |> put_session("net_config_ntp2", ntp2)
    |> put_session("net_config_ssh_key", ssh_key)
    |> put_session("net_config_ssid", ssid)
    |> put_session("net_config_security", security)
    |> put_session("net_config_psk", psk)
    |> put_session("net_config_identity", identity)
    |> put_session("net_config_password", password)
    |> put_session("net_config_domain", domain)
    |> put_session("net_config_name_servers", name_servers)
    |> put_session("net_config_ipv4_method", ipv4_method)
    |> put_session("net_config_ipv4_address", ipv4_address)
    |> put_session("net_config_ipv4_gateway", ipv4_gateway)
    |> put_session("net_config_ipv4_subnet_mask", ipv4_subnet_mask)
    |> put_session("net_config_reg_domain", reg_domain)
    |> redir("/credentials")
  end

  # /NETWORKCONFIG

  get "/credentials" do
    email = get_session(conn, "auth_config_email") || load_email() || ""
    pass = get_session(conn, "auth_config_password") || load_password() || ""
    server = get_session(conn, "auth_config_server") || load_server() || ""

    render_page(conn, "credentials",
      server: server,
      email: email,
      password: pass
    )
  end

  post "/configure_credentials" do
    {:ok, _, conn} = read_body(conn)

    case conn.body_params do
      %{"email" => email, "password" => pass, "server" => server} ->
        if server = test_uri(server) do
          FarmbotCore.Logger.info(1, "server valid: #{server}")
        else
          conn
          |> put_session("__error", "Server is not a valid URI")
          |> redir("/credentials")
        end

        conn
        |> put_session("email", email)
        |> put_session("password", pass)
        |> put_session("server", server)
        |> redir("/finish")

      _ ->
        conn
        |> put_session("__error", "Email, Server, or Password are missing or invalid")
        |> redir("/credentials")
    end
  end

  get "/finish" do
    FarmbotCore.Logger.error(1, "???")
    IO.inspect(get_session(conn))
    render_page(conn, "finish")
  end

  match(_, do: send_resp(conn, 404, "Page not found"))

  defp redir(conn, loc) do
    conn
    |> put_resp_header("location", loc)
    |> send_resp(302, loc)
  end

  defp render_page(conn, page, info \\ []) do
    page
    |> template_file()
    |> EEx.eval_file(info, engine: Phoenix.HTML.Engine)
    |> (fn {:safe, contents} -> send_resp(conn, 200, contents) end).()
  rescue
    e -> send_resp(conn, 500, "Failed to render page: #{page} inspect: #{Exception.message(e)}")
  end

  defp template_file(file) do
    "#{:code.priv_dir(:farmbot)}/static/templates/#{file}.html.eex"
  end

  defp remove_empty_string(""), do: nil
  defp remove_empty_string(str), do: str

  defp advanced_network do
    template_file("advanced_network")
    |> EEx.eval_file([])
    |> raw()
  end

  defp test_uri(nil), do: nil

  defp test_uri(uri) do
    case URI.parse(uri) do
      %URI{host: host, port: port, scheme: scheme}
      when scheme in ["https", "http"] and is_binary(host) and is_integer(port) ->
        uri

      _ ->
        FarmbotCore.Logger.error(1, "#{inspect(uri)} is not valid")
        nil
    end
  end

  defp load_last_reset_reason do
    @data_layer.load_last_reset_reason()
  end

  defp load_email do
    @data_layer.load_email()
  end

  defp load_password do
    @data_layer.load_password()
  end

  def load_server do
    @data_layer.load_server()
  end

  defp dump_logs do
    @data_layer.dump_logs()
  end

  defp dump_log_db do
    @data_layer.dump_log_db()
  end

  defp list_interfaces() do
    @network_layer.list_interfaces()
  end

  defp scan(interface) do
    @network_layer.scan(interface)
  end

  defp version, do: FarmbotCore.Project.version()
end
