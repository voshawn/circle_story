defmodule CircleStoryWeb.PageController do
  use CircleStoryWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
