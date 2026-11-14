# Spike #3162: which context functions write without asking who is writing,
# and which doors call them. Pure AST, no app code loaded:
#
#     elixir spike/unchecked_writes.exs            # the summary
#     elixir spike/unchecked_writes.exs --list     # every unchecked write
#     elixir spike/unchecked_writes.exs --doors    # every door call site
#     elixir spike/unchecked_writes.exs --baseline # rewrite the repo check's list
Code.require_file("../test/support/unchecked_writes.ex", __DIR__)

{flags, rest} = Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))
root = List.first(rest) || File.cwd!()

if "--baseline" in flags do
  list = Slipdock.UncheckedWrites.unchecked(root)
  File.write!(Path.join(root, "test/support/unchecked_writes.txt"), Enum.join(list, "\n") <> "\n")
  IO.puts("#{length(list)} written")
else
  Slipdock.UncheckedWrites.run(root, flags)
end
