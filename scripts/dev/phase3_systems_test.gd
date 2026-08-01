extends Node
## Focused regression for physical inventory, item records, villager identity, and schema 8 data.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")
const TEST_SEED := 731903

var _failures := PackedStringArray()


func _ready() -> void:
	RunSave.clear()
	var run := RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame
	Sim.set_paused(true)
	var entities := run.get_node("WorldView/Sorted/Entities")

	_expect(Resources.all().size() == 14, "all resource behavior is data-driven")
	_expect(Items.all().size() >= 24, "the launch item catalog contains twenty-four records")
	_expect(Jobs.all().size() >= 18, "the living-colony job catalog reaches the launch minimum")
	_expect(Buildings.all().size() >= 48, "the launch building catalog reaches forty-eight structures")
	var camp_job := Jobs.get_job(&"lumberer")
	_expect(camp_job != null and not camp_job.target_features.is_empty() \
		and not camp_job.workplace.is_empty() and camp_job.catchment_radius > 0,
		"field workplaces employ harvesters inside a declared catchment")
	var sample := ItemRecord.create(Items.get_item(&"iron_sword"), "test-item")
	sample.durability -= 7
	var sample_copy := ItemRecord.from_dict(sample.to_dict())
	_expect(sample_copy.uid == sample.uid and sample_copy.durability == sample.durability,
		"ItemRecord round-trips durability and stable identity")

	var ids: Dictionary = {}
	var named_and_unique := true
	for villager in Colony.villagers:
		named_and_unique = named_and_unique and not villager.profile.display_name.is_empty() \
			and not ids.has(villager.profile.stable_id)
		ids[villager.profile.stable_id] = true
	_expect(named_and_unique, "villagers receive deterministic unique identities and names")
	Colony.refresh_households()
	_expect(Colony.villagers.size() < 2 or not Colony.villagers[0].profile.partner_id.is_empty(),
		"eligible adults form persistent households")

	var warehouse := _force_raise(Buildings.get_building(&"warehouse"), entities)
	var granary := _force_raise(Buildings.get_building(&"granary"), entities)
	_expect(warehouse != null and granary != null, "specialized physical stores can be raised")
	if warehouse != null and granary != null:
		var deposited_warehouse := Colony.deposit_at(warehouse.centre_cell(), &"food", 100)
		var deposited_granary := Colony.deposit_at(granary.centre_cell(), &"food", 100)
		_expect(deposited_warehouse == 100 and deposited_granary == 100,
			"resources enter specific building inventories with capacity")
		var warehouse_before := int(warehouse.inventory.get(&"food", 0))
		var granary_before := int(granary.inventory.get(&"food", 0))
		Colony.apply_daily_spoilage()
		var warehouse_loss := warehouse_before - int(warehouse.inventory.get(&"food", 0))
		var granary_loss := granary_before - int(granary.inventory.get(&"food", 0))
		_expect(warehouse_loss > granary_loss and granary_loss > 0,
			"Granaries reduce spoilage without eliminating it")

		Colony.deposit_at(warehouse.centre_cell(), &"stone", 25)
		var stone_before := Colony.amount_of(&"stone")
		var overflow_before := int(Colony.overflow.get(&"stone", 0))
		warehouse.destroy()
		await get_tree().process_frame
		_expect(Colony.amount_of(&"stone") == stone_before \
			and int(Colony.overflow.get(&"stone", 0)) >= overflow_before + 25,
			"destroyed storage evacuates contents instead of deleting them")

	var sawmill := _force_raise(Buildings.get_building(&"sawmill"), entities)
	var sawing := Jobs.get_job(&"sawing")
	if sawmill != null and sawing != null:
		Colony.add(&"wood", 10)
		var source := Colony.nearest_storage_source(sawmill.centre_cell(), &"wood")
		var wood_before_buffer := Colony.amount_of(&"wood")
		var carried := Colony.withdraw_at(source, &"wood", int(sawing.cycle_cost.get(&"wood", 0)))
		var buffered_amount := Colony.deposit_building_input(sawmill, &"wood", carried)
		_expect(buffered_amount == carried and Colony.amount_of(&"wood") == wood_before_buffer \
			and Colony.available(&"wood") == wood_before_buffer - carried,
			"workshop inputs are hauled into a committed local buffer")
		_expect(Colony.consume_building_inputs(sawmill, sawing.cycle_cost) \
			and Colony.amount_of(&"wood") == wood_before_buffer - carried,
			"a production cycle consumes its local inputs exactly once")
		var made := Colony.deposit_building_output(sawmill, &"boards", 1)
		var output_load := Colony.withdraw_building_output(sawmill, &"boards", made)
		var output_store := Colony.nearest_storage_destination(sawmill.centre_cell(), &"boards")
		var stored_output := Colony.deposit_at(output_store, &"boards", output_load)
		_expect(made == 1 and stored_output == 1,
			"workshop output exists locally before a villager hauls it to storage")

	_expect(_physical_totals_match(), "aggregate stock is only a cache of physical inventories")
	var items_before := Colony.item_count()
	Colony.create_item(&"iron_sword")
	_expect(Colony.item_count() == items_before + 1, "crafted items are lightweight stored records")
	var equipped: Villager = Colony.villagers[0]
	equipped.set_job(&"warrior")
	equipped.refresh_equipment()
	_expect(equipped.profile.equipment.has(&"weapon") and Colony.item_count() == items_before,
		"best-available job policy withdraws suitable equipment from a real store")
	equipped.set_equipment_policy(&"none")
	_expect(not equipped.profile.equipment.has(&"weapon") and Colony.item_count() == items_before + 1,
		"none policy returns equipment without destroying it")

	var child := Colony.spawn_villager(World.nearest_walkable(World.keep_cell, 6), true) as Villager
	_expect(child != null and not child.is_adult(), "birth creates a child that matures after six days")
	if child != null:
		child.set_job(&"woodcutting")
		_expect(child.job.is_empty(), "children cannot be assigned to work")

	var clinic := _force_raise(Buildings.get_building(&"clinic"), entities)
	var medic_def := Jobs.get_job(&"medic")
	var patient: Villager = Colony.villagers[1]
	var medic: Villager = Colony.villagers[2]
	Colony.add(&"medicine", 4)
	patient.apply_status(&"infected", 60.0)
	patient.take_damage(15.0)
	medic.set_job(&"medic")
	var medicine_before := Colony.amount_of(&"medicine")
	var claimed_patient := clinic != null and medic_def != null and medic._try_claim_patient(medic_def)
	if claimed_patient:
		medic.stop()
		medic.position = patient.position
		medic._tick_healing(medic_def, medic_def.cycle_work * 2.0)
	if not (claimed_patient and not patient.statuses.has(&"infected") \
			and patient.profile.wounds.is_empty() and Colony.amount_of(&"medicine") < medicine_before):
		print("      clinic claimed=%s infected=%s wounds=%s medicine=%d/%d" % [
			claimed_patient, patient.statuses.has(&"infected"), patient.profile.wounds,
			Colony.amount_of(&"medicine"), medicine_before])
	_expect(claimed_patient and not patient.statuses.has(&"infected") \
		and patient.profile.wounds.is_empty() and Colony.amount_of(&"medicine") < medicine_before,
		"a staffed Clinic spends medicine to treat infection and wounds")

	var checkpoint := ColonyLedger.new()
	checkpoint.id = Realm.awake_id
	Abstractor.capture(checkpoint)
	_expect(int(checkpoint.state.get("physical_inventory", 0)) == 1 \
		and checkpoint.state.get("villagers", [])[0].has("record"),
		"schema 8 captures physical stores and villager records")
	var expected_stock := Colony.stock.duplicate(true)
	var source_for_saved_input := Colony.nearest_storage_source(sawmill.centre_cell(), &"wood")
	var saved_input_load := Colony.withdraw_at(source_for_saved_input, &"wood", 1)
	Colony.deposit_building_input(sawmill, &"wood", saved_input_load)
	var expected_buffered_wood := int(Colony.buffered.get(&"wood", 0))
	expected_stock = Colony.stock.duplicate(true)
	var expected_item_count := Colony.total_item_count()
	var expected_ids := _profile_ids()
	_expect(RunSave.SCHEMA_VERSION >= 8 and RunSave.save() and SaveService.flush(),
		"the current checkpoint commits the Phase-3 state")
	for node in entities.get_children():
		node.queue_free()
	Colony.villagers.clear()
	Colony.buildings.clear()
	await get_tree().process_frame
	_expect(RunSave.load_into(run, entities), "the current schema restores physical colony data")
	await get_tree().process_frame
	_expect(Colony.stock == expected_stock and _physical_totals_match(),
		"save/load conserves every stored resource")
	_expect(int(Colony.buffered.get(&"wood", 0)) == expected_buffered_wood,
		"save/load preserves committed workshop inputs")
	var restored_item_count := Colony.total_item_count()
	if restored_item_count != expected_item_count:
		print("      item count expected %d, restored %d" % [expected_item_count, restored_item_count])
	_expect(restored_item_count == expected_item_count, "save/load conserves stored items")
	_expect(_profile_ids() == expected_ids, "save/load preserves stable villager identities")

	Colony.distribute_legacy_stock({&"wood": 77, &"food": 33})
	_expect(Colony.amount_of(&"wood") == 77 and Colony.amount_of(&"food") == 33 \
		and _physical_totals_match(),
		"legacy global stock migrates deterministically with overflow and no loss")

	RunSave.clear()
	_report()


func _physical_totals_match() -> bool:
	var totals: Dictionary = {}
	for kind in Colony.KINDS:
		totals[kind] = int(Colony.overflow.get(kind, 0))
	for building in Colony.buildings:
		if not is_instance_valid(building):
			continue
		for raw_kind in building.inventory.keys():
			var kind := StringName(raw_kind)
			totals[kind] = int(totals.get(kind, 0)) + int(building.inventory.get(kind, 0))
		for buffer in [building.input_buffer, building.output_buffer]:
			for raw_kind in buffer.keys():
				var kind := StringName(raw_kind)
				totals[kind] = int(totals.get(kind, 0)) + int(buffer.get(kind, 0))
	for kind in Colony.KINDS:
		if int(totals.get(kind, 0)) != Colony.amount_of(kind):
			return false
	return true


func _profile_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive:
			ids.append(villager.profile.stable_id)
	ids.sort()
	return ids


func _force_raise(def: BuildingDef, parent: Node) -> Building:
	if def == null:
		return null
	for cell in World.grid.cell_count:
		var cells := World.grid.footprint_cells(World.grid.coord(cell), def.footprint)
		if cells.is_empty():
			continue
		var valid := true
		for footprint_cell in cells:
			if World.claimed[footprint_cell] != 0 \
					or not Terrain.WALKABLE.get(World.terrain[footprint_cell], false) \
					or Terrain.blocks_building(World.feature[footprint_cell]):
				valid = false
				break
		if not valid:
			continue
		var building: Building = BUILDING_SCENE.instantiate()
		building.setup(def, cell)
		building.position = Colony._building_origin(def, cell)
		parent.add_child(building)
		building.complete()
		return building
	return null


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Phase 3 systems test ===")
	if _failures.is_empty():
		print("all physical-inventory and living-villager checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
