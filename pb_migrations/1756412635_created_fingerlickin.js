/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "aenk1ilrzr3as7e",
    "created": "2025-08-28 20:23:55.418Z",
    "updated": "2025-08-28 20:23:55.418Z",
    "name": "fingerlickin",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "qk3vicwm",
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
  const collection = dao.findCollectionByNameOrId("aenk1ilrzr3as7e");

  return dao.deleteCollection(collection);
})
