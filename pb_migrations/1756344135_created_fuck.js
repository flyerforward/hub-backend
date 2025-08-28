/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "6oubcaeee50odge",
    "created": "2025-08-28 01:22:15.580Z",
    "updated": "2025-08-28 01:22:15.580Z",
    "name": "fuck",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "fjpdsfbd",
        "name": "shit",
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
  const collection = dao.findCollectionByNameOrId("6oubcaeee50odge");

  return dao.deleteCollection(collection);
})
