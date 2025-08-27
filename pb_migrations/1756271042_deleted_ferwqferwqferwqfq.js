/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db);
  const collection = dao.findCollectionByNameOrId("uokzid5ia4c6soj");

  return dao.deleteCollection(collection);
}, (db) => {
  const collection = new Collection({
    "id": "uokzid5ia4c6soj",
    "created": "2025-08-27 05:03:48.890Z",
    "updated": "2025-08-27 05:03:48.890Z",
    "name": "ferwqferwqferwqfq",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "1aw0ivpp",
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
})
