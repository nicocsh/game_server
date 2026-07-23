defmodule GameServerWeb.ChatNavigationTest do
  @moduledoc """
  The conversation a user opens must live in the URL, so a refresh restores it
  and other pages can link straight to it.
  """
  use GameServerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias GameServer.Groups

  setup :register_and_log_in_user

  defp own_group(user) do
    {:ok, group} = Groups.create_group(user.id, %{"title" => "Test Guild", "type" => "public"})
    group
  end

  test "a group chat URL selects that conversation (survives refresh)", %{conn: conn, user: user} do
    group = own_group(user)

    {:ok, _view, html} = live(conn, ~p"/chat?#{[type: "group", id: group.id]}")

    # The chat header shows the selected group — the same path a browser
    # refresh takes, since a reload re-requests this exact URL.
    assert html =~ "Test Guild"
  end

  test "opening a group from the sidebar pushes the URL", %{conn: conn, user: user} do
    group = own_group(user)

    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> element(~s([phx-click="open_group"][phx-value-id="#{group.id}"]))
    |> render_click()

    # The selection is reflected in the address bar, not just in memory, so a
    # refresh from here keeps the group open.
    assert_patch(view, ~p"/chat?#{[type: "group", id: group.id]}")
    assert render(view) =~ "Test Guild"
  end

  test "the group page links members to that group's chat", %{conn: conn, user: user} do
    group = own_group(user)

    {:ok, _view, html} = live(conn, ~p"/groups/#{group.id}")

    assert html =~ ~s(href="/chat?type=group&amp;id=#{group.id}")
    assert html =~ "Open chat"
  end

  test "the group page shows no chat link to non-members", %{user: user} do
    group = own_group(user)
    other = GameServer.AccountsFixtures.user_fixture()
    other_conn = log_in_user(Phoenix.ConnTest.build_conn(), other)

    {:ok, _view, html} = live(other_conn, ~p"/groups/#{group.id}")

    refute html =~ "Open chat"
  end
end
