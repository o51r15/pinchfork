defmodule Pinchflat.Accounts.Password do
  @moduledoc """
  Password hashing with PBKDF2-HMAC-SHA512 from Erlang's `:crypto`, so no native
  dependency is needed in the image.

  Stored format: `$pbkdf2-sha512$<iterations>$<salt b64>$<hash b64>`. The iteration count is
  stored with each hash, so it can be raised later without breaking existing passwords.
  """

  @iterations 210_000
  @salt_bytes 16
  @hash_bytes 64

  @doc """
  Hashes a password for storage.

  Returns binary()
  """
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    hash = derive(password, salt, iterations())

    "$pbkdf2-sha512$#{iterations()}$#{Base.encode64(salt, padding: false)}$#{Base.encode64(hash, padding: false)}"
  end

  @doc """
  Checks a password against a stored hash in constant time.

  Returns boolean()
  """
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    with ["", "pbkdf2-sha512", iter, salt64, hash64] <- String.split(stored, "$"),
         {iterations, ""} <- Integer.parse(iter),
         {:ok, salt} <- Base.decode64(salt64, padding: false),
         {:ok, expected} <- Base.decode64(hash64, padding: false) do
      Plug.Crypto.secure_compare(derive(password, salt, iterations, byte_size(expected)), expected)
    else
      _ -> false
    end
  end

  def verify(_password, _stored), do: false

  @doc """
  Does the same amount of work as a real check, for when no user matched. This keeps the
  response time the same whether or not a username exists.

  Returns false
  """
  def no_user_verify do
    derive("not-a-real-password", :crypto.strong_rand_bytes(@salt_bytes), iterations())
    false
  end

  # Tests use a low count so the suite stays fast; production always uses @iterations.
  defp iterations, do: Application.get_env(:pinchflat, :password_iterations, @iterations)

  defp derive(password, salt, iterations, length \\ @hash_bytes) do
    :crypto.pbkdf2_hmac(:sha512, password, salt, iterations, length)
  end
end
