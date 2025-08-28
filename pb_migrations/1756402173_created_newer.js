/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "kek9crhsuvxdm6w",
    "created": "2025-08-28 17:29:33.811Z",
    "updated": "2025-08-28 17:29:33.811Z",
    "name": "newer",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "p6t8ffb2",
        "name": "newer",
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
  const collection = dao.findCollectionByNameOrId("kek9crhsuvxdm6w");

  return dao.deleteCollection(collection);
})
