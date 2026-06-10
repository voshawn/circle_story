# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jido_ai,
  model_aliases: %{
    capable: "anthropic:claude-sonnet-4-20250514",
    fast: "anthropic:claude-haiku-4-5"
  }

config :circle_story, CircleStory.Jido, max_tasks: 1000, agent_pools: []

config :circle_story,
  ecto_repos: [CircleStory.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :circle_story, CircleStoryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CircleStoryWeb.ErrorHTML, json: CircleStoryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CircleStory.PubSub,
  live_view: [signing_salt: "/04+5aCS"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :circle_story, CircleStory.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  circle_story: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  circle_story: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# When true, rendered pages outline each text bounding box in red — a debug aid
# for tuning AI placement. Off by default; enabled in dev (see dev.exs).
config :circle_story, :debug_bounding_boxes, false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
