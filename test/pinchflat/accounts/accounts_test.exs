defmodule Pinchflat.AccountsTest do
  use Pinchflat.DataCase

  import Pinchflat.AccountsFixtures

  alias Pinchflat.Accounts
  alias Pinchflat.Accounts.User
  alias Pinchflat.Accounts.Password
  alias Pinchflat.Accounts.LoginThrottle

  describe "create_user/1" do
    test "hashes the password and never stores it in plain text" do
      user = user_fixture(%{username: "michael"})

      assert user.username == "michael"
      assert String.starts_with?(user.password_hash, "$pbkdf2-sha512$")
      refute user.password_hash =~ valid_password()
      assert is_nil(user.password)
    end

    test "requires a long enough password" do
      assert {:error, changeset} =
               Accounts.create_user(%{username: "michael", password: "short", password_confirmation: "short"})

      assert "Use at least 12 characters" in errors_on(changeset).password
    end

    test "requires the confirmation to match" do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: "michael",
                 password: valid_password(),
                 password_confirmation: "something else entirely"
               })

      assert "The passwords don't match" in errors_on(changeset).password_confirmation
    end

    test "rejects usernames that only differ by letter case" do
      user_fixture(%{username: "Michael"})

      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: "michael",
                 password: valid_password(),
                 password_confirmation: valid_password()
               })

      assert "That username is taken" in errors_on(changeset).username
    end

    test "rejects usernames with spaces or symbols" do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: "my name!",
                 password: valid_password(),
                 password_confirmation: valid_password()
               })

      assert errors_on(changeset).username != []
    end
  end

  describe "create_first_user/1" do
    test "only works while there are no users" do
      assert {:ok, %User{}} =
               Accounts.create_first_user(%{
                 username: "first",
                 password: valid_password(),
                 password_confirmation: valid_password()
               })

      assert {:error, :already_set_up} =
               Accounts.create_first_user(%{
                 username: "second",
                 password: valid_password(),
                 password_confirmation: valid_password()
               })
    end
  end

  describe "get_user_by_username_and_password/2" do
    test "returns the user for the right password, in any letter case" do
      user = user_fixture(%{username: "Michael"})

      assert %User{id: id} = Accounts.get_user_by_username_and_password("michael", valid_password())
      assert id == user.id
    end

    test "returns nil for a wrong password or unknown user" do
      user_fixture(%{username: "michael"})

      assert is_nil(Accounts.get_user_by_username_and_password("michael", "wrong password here"))
      assert is_nil(Accounts.get_user_by_username_and_password("nobody", valid_password()))
    end
  end

  describe "session tokens" do
    test "a token finds its user until it is deleted" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token).id == user.id

      Accounts.delete_user_session_token(token)
      assert is_nil(Accounts.get_user_by_session_token(token))
    end

    test "an unknown token finds nothing" do
      assert is_nil(Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32)))
      assert is_nil(Accounts.get_user_by_session_token(nil))
    end
  end

  describe "update_user_password/3" do
    test "changes the password and signs out other sessions" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      new_password = "a brand new password"

      assert {:ok, _} =
               Accounts.update_user_password(user, valid_password(), %{
                 password: new_password,
                 password_confirmation: new_password
               })

      assert Accounts.get_user_by_username_and_password(user.username, new_password)
      assert is_nil(Accounts.get_user_by_session_token(token))
    end

    test "refuses when the current password is wrong" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_user_password(user, "not my password", %{
                 password: "a brand new password",
                 password_confirmation: "a brand new password"
               })

      assert "That isn't your current password" in errors_on(changeset).current_password
    end
  end

  describe "Password" do
    test "verify/2 is false for malformed hashes" do
      refute Password.verify("anything", "not-a-hash")
      refute Password.verify("anything", nil)
    end
  end

  describe "LoginThrottle" do
    test "blocks an address after 10 failures and resets on success" do
      key = "test-#{System.unique_integer([:positive])}"

      for _ <- 1..9, do: LoginThrottle.record_failure(key)
      refute LoginThrottle.blocked?(key)

      LoginThrottle.record_failure(key)
      assert LoginThrottle.blocked?(key)

      LoginThrottle.reset(key)
      refute LoginThrottle.blocked?(key)
    end
  end
end
