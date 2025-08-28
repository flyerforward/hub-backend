/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "k88bjlvzwnpq3hi",
    "created": "2025-08-28 17:20:19.527Z",
    "updated": "2025-08-28 17:20:19.527Z",
    "name": "newest",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "fwwbhopm",
        "name": "newest",
        "type": "text",
        "required": false,
        "presentable": false,
        "unique": false,
        "options": {
          "min": null,
          "max": null,
          "pattern": ""
        }
      }
    ],
    "indexes": [],
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "options": {}
  });

  return Dao(db).saveCollection(collection);
}, (db) => {
  const dao = new Dao(db);
  const collection = dao.findCollectionByNameOrId("k88bjlvzwnpq3hi");

  return dao.deleteCollection(collection);
})
