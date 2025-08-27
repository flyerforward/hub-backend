/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "c419cdsa5fp4on9",
    "created": "2025-08-27 05:13:49.445Z",
    "updated": "2025-08-27 05:13:49.445Z",
    "name": "fred",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "hlyrf6mt",
        "name": "fred",
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
  const collection = dao.findCollectionByNameOrId("c419cdsa5fp4on9");

  return dao.deleteCollection(collection);
})
