/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "l96p9dw6f437i87",
    "created": "2025-08-27 17:25:50.747Z",
    "updated": "2025-08-27 17:25:50.747Z",
    "name": "test7654321",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "4dnqpvri",
        "name": "field",
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
  const collection = dao.findCollectionByNameOrId("l96p9dw6f437i87");

  return dao.deleteCollection(collection);
})
