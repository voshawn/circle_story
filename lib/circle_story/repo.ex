defmodule CircleStory.Repo do
  use Ecto.Repo,
    otp_app: :circle_story,
    adapter: Ecto.Adapters.SQLite3
end
