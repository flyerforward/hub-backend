/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "oxqv69jgx2j7uvw",
    "created": "2025-08-28 01:20:31.609Z",
    "updated": "2025-08-28 01:20:31.609Z",
    "name": "fingerlickin",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "illm1dcu",
        "name": "good",
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
  const collection = dao.findCollectionByNameOrId("oxqv69jgx2j7uvw");

  return dao.deleteCollection(collection);
})
