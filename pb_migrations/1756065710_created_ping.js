/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "vs394al5h0r5onf",
    "created": "2025-08-24 20:01:50.485Z",
    "updated": "2025-08-24 20:01:50.485Z",
    "name": "ping",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "jvmztkej",
        "name": "pong",
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
  const collection = dao.findCollectionByNameOrId("vs394al5h0r5onf");

  return dao.deleteCollection(collection);
})
