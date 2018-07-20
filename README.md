# ExUnit Clustered Cases

This project provides an extension for ExUnit for running tests against a
clustered application. It provides an easy way to spin up multiple nodes,
multiple clusters, and test a variety of scenarios in parallel without needing
to manage the clustering aspect yourself.

**NOTE:** This project is still a work in progress for the moment until I have
worked out some kinks with passing anonymous functions to nodes in the cluster
from dynamically compiled modules. See the roadmap for more information.

## Installation

This package is not yet on Hex, but will be soon as `:ex_unit_clustered_case`.

In the mean time, you can add it to your project like so:

```elixir
def deps do
  [
    {:ex_unit_clustered_case, github: "bitwalker/ex_unit_clustered_case"}
  ]
end
```

You can generate the docs with `mix docs` from a local git checkout.

## Roadmap

- [ ] Address bug with passing anonymous functions from test modules
- [ ] Add support for disabling auto-clustering in favor of letting tools like
      `libcluster` do the work.


## License

Apache 2, see the `LICENSE` file for more information.
