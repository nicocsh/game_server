defmodule GameServerWeb.Plugs.IpBanTest do
  use GameServer.DataCase, async: false

  alias GameServer.IpBans
  alias GameServerWeb.Plugs.IpBan

  setup do
    IpBan.init_table()

    on_exit(fn ->
      Enum.each(:ets.tab2list(:ip_bans), fn {ip, _} -> :ets.delete(:ip_bans, ip) end)
    end)

    :ok
  end

  test "ban/2 applies locally and persists to the database" do
    :ok = IpBan.ban("203.0.113.7", :timer.hours(1))

    assert IpBan.banned?("203.0.113.7")
    assert [%{ip: "203.0.113.7", expires_at: %DateTime{}}] = IpBans.list_active()
  end

  test "permanent bans persist with nil expires_at" do
    :ok = IpBan.ban("203.0.113.8")

    assert [%{ip: "203.0.113.8", expires_at: nil}] = IpBans.list_active()
  end

  test "unban/1 removes the ban locally and from the database" do
    :ok = IpBan.ban("203.0.113.9")
    :ok = IpBan.unban("203.0.113.9")

    refute IpBan.banned?("203.0.113.9")
    assert IpBans.list_active() == []
  end

  test "load_persisted/0 restores bans into ETS" do
    {:ok, _} = IpBans.upsert_ban("203.0.113.10", nil)

    {:ok, _} =
      IpBans.upsert_ban("203.0.113.11", DateTime.add(DateTime.utc_now(), 3600, :second))

    # expired ban must not be restored
    {:ok, _} =
      IpBans.upsert_ban("203.0.113.12", DateTime.add(DateTime.utc_now(), -60, :second))

    :ok = IpBan.load_persisted()

    assert IpBan.banned?("203.0.113.10")
    assert IpBan.banned?("203.0.113.11")
    refute IpBan.banned?("203.0.113.12")
  end

  test "apply_remote/3 mirrors events without touching the database" do
    :ok = IpBan.apply_remote(:banned, "203.0.113.13", nil)
    assert IpBan.banned?("203.0.113.13")
    assert IpBans.list_active() == []

    :ok = IpBan.apply_remote(:unbanned, "203.0.113.13", nil)
    refute IpBan.banned?("203.0.113.13")
  end
end
