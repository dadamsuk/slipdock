[path] = System.argv()
f = path |> File.read!() |> Jason.decode!()
d = fn k -> Base.url_decode64!(f[k], padding: false) end
{:ok, _} = Application.ensure_all_started(:wax_)
ch = Wax.new_authentication_challenge(origin: "https://slipdock.example.com", rp_id: "slipdock.example.com", user_verification: "required")
ch = %{ch | bytes: d.("challenge")}
cose = %{1 => 2, 3 => -7, -1 => 1, -2 => d.("x"), -3 => d.("y")}
cred = d.("credential_id")
IO.inspect(Wax.authenticate(cred, d.("authenticator_data"), d.("signature"), d.("client_data_json"), ch, [{cred, cose}]) |> elem(0), label: "wax on the good assertion")
bad = d.("signature") |> :binary.bin_to_list() |> List.update_at(-1, &Bitwise.bxor(&1, 1)) |> :binary.list_to_bin()
IO.inspect(Wax.authenticate(cred, d.("authenticator_data"), bad, d.("client_data_json"), ch, [{cred, cose}]) |> elem(0), label: "wax on a tampered signature")
other = %{ch | bytes: :crypto.hash(:sha256, "other text")}
IO.inspect(Wax.authenticate(cred, d.("authenticator_data"), d.("signature"), d.("client_data_json"), other, [{cred, cose}]) |> elem(0), label: "wax with another challenge")
