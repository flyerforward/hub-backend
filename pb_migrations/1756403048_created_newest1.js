/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "xiz67lg7yilmqgt",
    "created": "2025-08-28 17:44:08.730Z",
    "updated": "2025-08-28 17:44:08.730Z",
    "name": "newest1",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "utkg5ux9",
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
  const collection = dao.findCollectionByNameOrId("xiz67lg7yilmqgt");

  return dao.deleteCollection(collection);
})
