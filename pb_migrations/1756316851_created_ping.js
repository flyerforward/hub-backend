/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "dh69spjou6x5qb9",
    "created": "2025-08-27 17:47:31.693Z",
    "updated": "2025-08-27 17:47:31.693Z",
    "name": "ping",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "rnnyckyy",
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
  const collection = dao.findCollectionByNameOrId("dh69spjou6x5qb9");

  return dao.deleteCollection(collection);
})
