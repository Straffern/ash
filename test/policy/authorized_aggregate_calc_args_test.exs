# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Policy.AuthorizedAggregateCalcArgsTest do
  @moduledoc """
  Verifies that a destination read policy calling an argumented calculation is
  applied to authorized relationship aggregates. Direct reads and has_many
  loads must see the same visible set as the count. Regression coverage for
  calculation `arg/1` substitution on the aggregate authorization path.
  """
  use ExUnit.Case, async: false

  defmodule Child do
    @moduledoc false
    use Ash.Resource,
      domain: Ash.Test.Policy.AuthorizedAggregateCalcArgsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:section_id, :uuid, allow_nil?: false, public?: true)
    end

    calculations do
      calculate :in_section?, :boolean, expr(section_id in ^arg(:section_ids)) do
        argument(:section_ids, {:array, :uuid}, allow_nil?: false)
      end
    end

    relationships do
      belongs_to(:parent, Ash.Test.Policy.AuthorizedAggregateCalcArgsTest.Parent,
        public?: true,
        allow_nil?: false
      )
    end

    actions do
      default_accept(:*)
      defaults([:read, :destroy, create: :*, update: :*])
    end

    policies do
      policy action_type(:read) do
        authorize_if(expr(in_section?(section_ids: ^actor(:section_ids))))
      end

      policy action_type([:create, :update, :destroy]) do
        authorize_if(always())
      end
    end
  end

  defmodule Parent do
    @moduledoc false
    use Ash.Resource,
      domain: Ash.Test.Policy.AuthorizedAggregateCalcArgsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
    end

    relationships do
      has_many(:children, Child)
    end

    aggregates do
      count(:count_of_children, :children)
    end

    actions do
      default_accept(:*)
      defaults([:read, :destroy, create: :*, update: :*])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource(Parent)
      resource(Child)
    end
  end

  describe "child policy referencing an argumented calculation" do
    setup do
      visible_section_id = "11111111-1111-4111-8111-111111111111"
      hidden_section_id = "22222222-2222-4222-8222-222222222222"
      ash_opts = [actor: %{section_ids: [visible_section_id]}, authorize?: true]

      {:ok, parent} =
        Parent
        |> Ash.Changeset.for_create(:create, %{})
        |> Ash.create(authorize?: false)

      {:ok, visible_child} =
        Child
        |> Ash.Changeset.for_create(:create, %{
          section_id: visible_section_id,
          parent_id: parent.id
        })
        |> Ash.create(authorize?: false)

      {:ok, _hidden_child} =
        Child
        |> Ash.Changeset.for_create(:create, %{
          section_id: hidden_section_id,
          parent_id: parent.id
        })
        |> Ash.create(authorize?: false)

      %{parent: parent, visible_child: visible_child, ash_opts: ash_opts}
    end

    test "direct read of child filters by calculation arguments", %{
      visible_child: visible_child,
      ash_opts: ash_opts
    } do
      assert {:ok, [%Child{id: id}]} = Ash.read(Child, ash_opts)
      assert id == visible_child.id
    end

    test "has_many load on parent filters child by calculation arguments",
         %{parent: parent, visible_child: visible_child, ash_opts: ash_opts} do
      loaded = Ash.load!(parent, [:children], ash_opts)
      assert [%Child{id: id}] = loaded.children
      assert id == visible_child.id
    end

    test "count aggregate on parent applies calculation arguments to dest policy",
         %{parent: parent, ash_opts: ash_opts} do
      loaded = Ash.load!(parent, [:count_of_children], ash_opts)
      assert loaded.count_of_children == 1
    end

    test "unauthorized count includes children hidden by dest policy",
         %{parent: parent} do
      loaded = Ash.load!(parent, [:count_of_children], authorize?: false)
      assert loaded.count_of_children == 2
    end
  end
end
