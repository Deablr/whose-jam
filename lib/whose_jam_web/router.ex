defmodule WhoseJamWeb.Router do
  use WhoseJamWeb, :router

  # No Content-Security-Policy yet: a useful one has to allow the Spotify
  # Web Playback SDK, its iframes and Google Fonts. Tracked as a follow-up.
  # sobelow_skip ["Config.CSP"]
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WhoseJamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WhoseJamWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/play/:code", PlayLive
    live "/host/:code", HostLive
    # The TV and host console are one screen; keep the old TV URL working.
    live "/tv/:code", HostLive

    get "/claim/:token", PlayerSessionController, :claim
    get "/auth/:provider", MusicAuthController, :authorize
    get "/auth/:provider/callback", MusicAuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", WhoseJamWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:whose_jam, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WhoseJamWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
