/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "19kenzq1p92mcgt",
    "created": "2025-08-27 01:03:08.078Z",
    "updated": "2025-08-27 01:03:08.078Z",
    "name": "terea",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "ohscruv3",
        "name": "tes",
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
  const collection = dao.findCollectionByNameOrId("19kenzq1p92mcgt");

  return dao.deleteCollection(collection);
})
